package com.linh18nd.flutter_live2d

import android.content.Context
import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.GLES20
import android.os.SystemClock
import android.view.MotionEvent
import android.view.TextureView
import android.view.View
import io.flutter.plugin.platform.PlatformView
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class Live2DPlatformView(
    context: Context,
    private val viewId: Int,
    private val onDisposed: (Int) -> Unit,
) : PlatformView {
    companion object {
        private var assetManagerSet = false
    }

    private val nativeHandle: Long
    private val renderView: Live2DTextureView

    init {
        if (!assetManagerSet) {
            Live2DBridge.nativeSetAssetManager(context.assets)
            assetManagerSet = true
        }
        nativeHandle = Live2DBridge.nativeCreateView()
        renderView = Live2DTextureView(context, nativeHandle)
    }

    override fun getView(): View = renderView

    override fun dispose() {
        // Both surface destruction AND native destroy must happen on the
        // render hub thread, otherwise the hub may crash mid-frame on a
        // freed view. The call blocks until the hub finishes cleanup.
        Live2DRenderHub.disposeViewSync(nativeHandle)
        onDisposed(viewId)
    }

    fun loadModel(modelDir: String, modelFileName: String, callback: (Boolean) -> Unit) {
        Live2DRenderHub.queueEvent(nativeHandle) {
            val ok = Live2DBridge.nativeLoadModel(nativeHandle, modelDir, modelFileName)
            callback(ok)
        }
    }

    fun unloadModel(callback: () -> Unit) {
        Live2DRenderHub.queueEvent(nativeHandle) {
            Live2DBridge.nativeUnloadModel(nativeHandle)
            callback()
        }
    }

    fun setRenderingPaused(paused: Boolean) {
        Live2DRenderHub.setPaused(nativeHandle, paused)
    }

    fun startMotion(group: String, index: Int, priority: Int) {
        Live2DRenderHub.queueEvent(nativeHandle) {
            Live2DBridge.nativeStartMotion(nativeHandle, group, index, priority)
        }
    }

    fun setExpression(index: Int) {
        Live2DRenderHub.queueEvent(nativeHandle) {
            Live2DBridge.nativeSetExpression(nativeHandle, index)
        }
    }

    fun setParameter(parameterId: String, value: Float) {
        Live2DRenderHub.queueEvent(nativeHandle) {
            Live2DBridge.nativeSetParameter(nativeHandle, parameterId, value)
        }
    }

    fun setMotionSpeed(speed: Float) {
        Live2DRenderHub.queueEvent(nativeHandle) {
            Live2DBridge.nativeSetMotionSpeed(nativeHandle, speed)
        }
    }
}

private class Live2DTextureView(
    context: Context,
    private val nativeHandle: Long,
) : TextureView(context), TextureView.SurfaceTextureListener {

    init {
        surfaceTextureListener = this
        isOpaque = false
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        val x = event.x
        val y = event.y
        when (event.action) {
            MotionEvent.ACTION_DOWN -> Live2DRenderHub.queueEvent(nativeHandle) {
                Live2DBridge.nativeOnTouchBegan(nativeHandle, x, y)
            }
            MotionEvent.ACTION_MOVE -> Live2DRenderHub.queueEvent(nativeHandle) {
                Live2DBridge.nativeOnTouchMoved(nativeHandle, x, y)
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> Live2DRenderHub.queueEvent(nativeHandle) {
                Live2DBridge.nativeOnTouchEnded(nativeHandle, x, y)
            }
        }
        return true
    }

    override fun onSurfaceTextureAvailable(surface: SurfaceTexture, width: Int, height: Int) {
        Live2DRenderHub.registerView(nativeHandle, surface, width, height)
    }

    override fun onSurfaceTextureSizeChanged(surface: SurfaceTexture, width: Int, height: Int) {
        Live2DRenderHub.setSurfaceSize(nativeHandle, width, height)
    }

    override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean {
        // The TextureView is about to release this SurfaceTexture; we MUST
        // destroy our EGLSurface that wraps it before returning, otherwise
        // the hub thread will swap onto a dead surface and crash.
        Live2DRenderHub.disposeViewSync(nativeHandle)
        return true
    }

    override fun onSurfaceTextureUpdated(surface: SurfaceTexture) = Unit
}

/**
 * Process-wide rendering hub for all Live2D views.
 *
 * One thread + one EGL context for the whole process. Each view has its own
 * EGL surface bound to its TextureView's SurfaceTexture. The hub's render
 * loop iterates over all registered views, makeCurrent each surface, calls
 * native draw, swapBuffers.
 *
 * Why a single context? The Cubism Native SDK uses static singletons (shader
 * program, offscreen mask manager) that don't survive cross-context use even
 * with EGL share lists. Keeping all GL state in one context makes everything
 * coherent — per-view isolation still happens at the C++ struct level.
 *
 * Disposal is the tricky part: the C++ Live2DView struct must be deleted on
 * the hub thread (not the main thread), otherwise the hub may crash mid-
 * frame on a freed view. `disposeViewSync` flags a view as doomed, then
 * blocks until the hub thread finishes cleanup.
 */
private object Live2DRenderHub {

    private class HubView(
        val handle: Long,
        val surfaceTexture: SurfaceTexture,
        @Volatile var width: Int,
        @Volatile var height: Int,
        @Volatile var paused: Boolean = false,
        @Volatile var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE,
        @Volatile var initialized: Boolean = false,
        @Volatile var sizeDirty: Boolean = true,
        @Volatile var doomed: Boolean = false,
        @Volatile var disposeLatch: CountDownLatch? = null,
    )

    private val running = AtomicBoolean(false)
    private val viewsLock = Any()
    private val views = mutableListOf<HubView>()
    private val pendingActions = LinkedBlockingQueue<Pair<Long, () -> Unit>>()
    private val newSurfaces = LinkedBlockingQueue<HubView>()

    private var thread: Thread? = null
    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglConfig: EGLConfig? = null
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT

    fun registerView(handle: Long, surface: SurfaceTexture, width: Int, height: Int) {
        // If the same handle was registered before (rare; should not happen
        // with current lifecycle), make sure we discard the old entry first.
        val view = HubView(handle, surface, width, height)
        synchronized(viewsLock) {
            views.removeAll { it.handle == handle }
            views.add(view)
            ensureStarted()
        }
        newSurfaces.offer(view)
    }

    fun queueEvent(handle: Long, action: () -> Unit) {
        pendingActions.offer(handle to action)
    }

    fun setPaused(handle: Long, paused: Boolean) {
        synchronized(viewsLock) {
            views.firstOrNull { it.handle == handle }?.paused = paused
        }
    }

    fun setSurfaceSize(handle: Long, width: Int, height: Int) {
        synchronized(viewsLock) {
            views.firstOrNull { it.handle == handle }?.let {
                it.width = width
                it.height = height
                it.sizeDirty = true
            }
        }
    }

    /**
     * Mark a view for disposal and wait for the hub thread to finish freeing
     * its native resources. Idempotent. Returns immediately if the view is
     * already gone or never existed.
     */
    fun disposeViewSync(handle: Long, timeoutMs: Long = 2000) {
        val latch: CountDownLatch
        synchronized(viewsLock) {
            val v = views.firstOrNull { it.handle == handle } ?: return
            if (v.doomed) {
                // Already in the disposal pipeline — wait on the existing latch.
                latch = v.disposeLatch ?: return
            } else {
                latch = CountDownLatch(1)
                v.disposeLatch = latch
                v.doomed = true
            }
        }
        try {
            latch.await(timeoutMs, TimeUnit.MILLISECONDS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    private fun ensureStarted() {
        if (running.get()) return
        running.set(true)
        thread = Thread({ renderLoop() }, "Live2D-RenderHub").also { it.start() }
    }

    private fun renderLoop() {
        if (!initEgl()) {
            running.set(false)
            return
        }

        while (running.get()) {
            // 1. Spin up EGL surfaces for newly registered views.
            while (true) {
                val nv = newSurfaces.poll() ?: break
                createSurfaceForView(nv)
            }

            // 2. Reap doomed views BEFORE we draw anything else this iteration,
            //    so we never touch a doomed view's native state again.
            reapDoomed()

            // 3. Drain queued events (loadModel, startMotion, ...).
            //    Skip events for views that have been disposed.
            while (true) {
                val pair = pendingActions.poll() ?: break
                val (handle, action) = pair
                val target = synchronized(viewsLock) {
                    views.firstOrNull { it.handle == handle && !it.doomed }
                }
                if (target != null && target.eglSurface != EGL14.EGL_NO_SURFACE) {
                    EGL14.eglMakeCurrent(
                        eglDisplay, target.eglSurface, target.eglSurface, eglContext
                    )
                    action()
                }
            }

            // 4. Render every active view.
            val snapshot = synchronized(viewsLock) { views.toList() }
            var anyDrawn = false
            for (v in snapshot) {
                if (v.doomed) continue
                if (v.paused) continue
                if (v.eglSurface == EGL14.EGL_NO_SURFACE) continue
                if (v.width <= 0 || v.height <= 0) continue

                EGL14.eglMakeCurrent(eglDisplay, v.eglSurface, v.eglSurface, eglContext)

                if (!v.initialized) {
                    Live2DBridge.nativeOnSurfaceCreated(v.handle)
                    v.initialized = true
                    v.sizeDirty = true
                }
                if (v.sizeDirty) {
                    Live2DBridge.nativeOnSurfaceChanged(v.handle, v.width, v.height)
                    v.sizeDirty = false
                }

                Live2DBridge.nativeOnDrawFrame(v.handle)
                EGL14.eglSwapBuffers(eglDisplay, v.eglSurface)
                anyDrawn = true
            }

            SystemClock.sleep(if (anyDrawn) 16 else 50)
        }

        teardownAll()
    }

    private fun reapDoomed() {
        // Snapshot the doomed list under lock, but don't remove from `views`
        // yet — that happens after native cleanup so concurrent lookups still
        // see the entry as "doomed" rather than disappearing mid-flight.
        val doomed = synchronized(viewsLock) { views.filter { it.doomed }.toList() }
        if (doomed.isEmpty()) return

        for (v in doomed) {
            try {
                if (v.eglSurface != EGL14.EGL_NO_SURFACE) {
                    EGL14.eglMakeCurrent(
                        eglDisplay, v.eglSurface, v.eglSurface, eglContext
                    )
                    Live2DBridge.nativeOnSurfaceDestroyed(v.handle)
                    EGL14.eglMakeCurrent(
                        eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, eglContext
                    )
                    EGL14.eglDestroySurface(eglDisplay, v.eglSurface)
                    v.eglSurface = EGL14.EGL_NO_SURFACE
                }
                Live2DBridge.nativeDestroyView(v.handle)
            } finally {
                synchronized(viewsLock) { views.remove(v) }
                v.disposeLatch?.countDown()
            }
        }
    }

    private fun createSurfaceForView(v: HubView) {
        val cfg = eglConfig ?: return
        val surface = EGL14.eglCreateWindowSurface(
            eglDisplay, cfg, v.surfaceTexture, intArrayOf(EGL14.EGL_NONE), 0
        )
        if (surface == EGL14.EGL_NO_SURFACE) {
            return
        }
        v.eglSurface = surface
        v.initialized = false
        v.sizeDirty = true
    }

    private fun initEgl(): Boolean {
        eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        if (eglDisplay == EGL14.EGL_NO_DISPLAY) return false

        val version = IntArray(2)
        if (!EGL14.eglInitialize(eglDisplay, version, 0, version, 1)) return false

        val configAttribs = intArrayOf(
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL14.EGL_RED_SIZE, 8,
            EGL14.EGL_GREEN_SIZE, 8,
            EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_DEPTH_SIZE, 16,
            EGL14.EGL_NONE
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val numConfig = IntArray(1)
        if (!EGL14.eglChooseConfig(
                eglDisplay, configAttribs, 0, configs, 0, 1, numConfig, 0
            ) || numConfig[0] <= 0
        ) return false
        eglConfig = configs[0]

        val contextAttribs = intArrayOf(
            EGL14.EGL_CONTEXT_CLIENT_VERSION, 2,
            EGL14.EGL_NONE
        )
        eglContext = EGL14.eglCreateContext(
            eglDisplay, configs[0], EGL14.EGL_NO_CONTEXT, contextAttribs, 0
        )
        return eglContext != EGL14.EGL_NO_CONTEXT
    }

    @Suppress("unused")
    private fun teardownAll() {
        synchronized(viewsLock) {
            for (v in views) {
                if (v.eglSurface != EGL14.EGL_NO_SURFACE) {
                    EGL14.eglDestroySurface(eglDisplay, v.eglSurface)
                    v.eglSurface = EGL14.EGL_NO_SURFACE
                }
                v.disposeLatch?.countDown()
            }
            views.clear()
        }
        if (eglContext != EGL14.EGL_NO_CONTEXT) {
            EGL14.eglMakeCurrent(
                eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT
            )
            EGL14.eglDestroyContext(eglDisplay, eglContext)
            eglContext = EGL14.EGL_NO_CONTEXT
        }
        eglConfig = null
    }
}
