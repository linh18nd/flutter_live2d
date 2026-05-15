import Flutter
import UIKit
import OpenGLES
import Darwin

/// Writes to **stderr** so lines appear in the integrated terminal used by
/// `flutter run`. The Dart debug console often misses native NSLog output.
enum Live2DNativeLog {
    static func line(_ message: String) {
        let full = "[FlutterLive2D] \(message)\n"
        full.withCString { fputs($0, stderr) }
        fflush(stderr)
    }
}

// MARK: - Factory

class Live2DViewFactory: NSObject, FlutterPlatformViewFactory {

    private let messenger: FlutterBinaryMessenger
    private let onCreated:  (Int64, Live2DFlutterView) -> Void
    private let onDisposed: (Int64, ObjectIdentifier) -> Void

    init(messenger: FlutterBinaryMessenger,
         onCreated:  @escaping (Int64, Live2DFlutterView) -> Void,
         onDisposed: @escaping (Int64, ObjectIdentifier) -> Void) {
        self.messenger  = messenger
        self.onCreated  = onCreated
        self.onDisposed = onDisposed
        super.init()
    }

    func create(withFrame frame: CGRect,
                viewIdentifier viewId: Int64,
                arguments args: Any?) -> FlutterPlatformView {
        let v = Live2DFlutterView(frame: frame, viewId: viewId,
                                  messenger: messenger, onDisposed: onDisposed)
        onCreated(viewId, v)
        return v
    }
}

// MARK: - PlatformView

class Live2DFlutterView: NSObject, FlutterPlatformView {

    let viewId: Int64
    private let glView: Live2DGLView
    private let onDisposed: (Int64, ObjectIdentifier) -> Void

    init(frame: CGRect, viewId: Int64,
         messenger: FlutterBinaryMessenger,
         onDisposed: @escaping (Int64, ObjectIdentifier) -> Void) {
        self.viewId     = viewId
        self.onDisposed = onDisposed
        self.glView     = Live2DGLView(frame: frame)
        super.init()
    }

    deinit { onDisposed(viewId, ObjectIdentifier(self)) }

    func view() -> UIView { glView }

    func loadModelAsync(modelDir: String, fileName: String,
                        completion: @escaping (Bool) -> Void) {
        glView.loadModelAsync(modelDir: modelDir, fileName: fileName,
                              completion: completion)
    }
    func unloadModel()                                   { glView.unloadModelAsync() }
    func setRenderingPaused(_ p: Bool)                   { glView.setRenderingPaused(p) }
    func startMotion(group: String, index: Int32, priority: Int32) {
        glView.startMotion(group: group, index: index, priority: priority)
    }
    func setExpression(index: Int32)                     { glView.setExpression(index: index) }
    func setParameter(parameterId: String, value: Float) {
        glView.setParameter(parameterId: parameterId, value: value)
    }
    func setMotionSpeed(_ speed: Float) {
        glView.setMotionSpeed(speed)
    }
}

// MARK: - Live2DGLView
//
// Why UIView instead of GLKView
// ─────────────────────────────
// GLKView.bindDrawable() lazily calls its private _createFramebuffer whenever
// it detects the view size has changed (checking drawableSize vs. the layer's
// current bounds). _createFramebuffer calls
//   EAGLContext.renderbufferStorage:fromDrawable:
// which internally calls CAEAGLLayer.nativeWindow → CALayer.setContents: —
// a UIKit API that iOS strictly enforces on the main thread.
//
// No matter how we sequence calls, GLKView can silently re-invoke
// _createFramebuffer from the render thread any time the size changes,
// producing "Modifying properties of a view's layer off the main thread is
// not allowed" warnings and GL state corruption.
//
// Fix: replace GLKView with a plain UIView whose CAEAGLLayer we configure
// ourselves. We call renderbufferStorage:fromDrawable: ONLY on the main
// thread (in recreateFramebufferOnMainThread). The render thread NEVER
// calls any UIKit / EAGL drawable API — it only calls glBindFramebuffer
// with our pre-built FBO objects.
//
// Threading model
// ───────────────
// All GL work (model load, draw, motion, parameters) runs on `renderQueue`,
// a serial background queue that owns the EAGLContext.
// Main thread:
//   • UIKit view lifecycle (init, layoutSubviews, didMoveToWindow, touches)
//   • CADisplayLink callbacks → schedule coalesced pumps on renderQueue
//   • FBO (re)creation via recreateFramebufferOnMainThread()
//
// renderQueue.sync from main is always safe because nothing on renderQueue
// ever dispatches back to main (confirmed by the deinit pattern and wrapper).

class Live2DGLView: UIView {

    // Make the backing layer a CAEAGLLayer (not the default CALayer).
    override class var layerClass: AnyClass { CAEAGLLayer.self }
    private var eaglLayer: CAEAGLLayer { layer as! CAEAGLLayer }

    // ── Shared GL resources ───────────────────────────────────────────────────
    //
    // All Live2D views share ONE EAGLContext and ONE serial render queue.
    //
    // Why a single context (not EAGLSharegroup):
    //   Cubism uses global singletons — CubismShader_OpenGLES2 compiles GL
    //   shader programs once and caches GLuint IDs. With separate contexts,
    //   even within a sharegroup, the iOS Simulator's software GL does NOT
    //   reliably share program objects; the cached IDs are invalid in the
    //   second context and rendering silently produces black output.
    //   A single shared context eliminates all cross-context issues entirely.
    //
    // Why a single serial render queue:
    //   Two concurrent GCD threads each making GL calls into the same context
    //   without locking is undefined behaviour. A single serial queue serialises
    //   all GL work while still keeping the main thread fully unblocked.
    //   At 60 fps each model render is ≤ 4 ms; two renders fit comfortably
    //   within a single 16.67 ms vsync budget.
    //
    // Each view still has its OWN FBO / renderbuffer pair backed by its own
    // CAEAGLLayer, so presentation is independent per-view.
    private static let sharedContext: EAGLContext = {
        guard let ctx = EAGLContext(api: .openGLES2) else {
            fatalError("Failed to create OpenGL ES 2 context")
        }
        return ctx
    }()
    private static let sharedRenderQueue = DispatchQueue(
        label: "live2d.render.shared", qos: .userInteractive)

    /// Set to `true` (on the render queue) while any view's
    /// `recreateFramebufferOnMainThread` has the shared context current on
    /// the main thread.  ALL pumps from ALL views check this flag and skip
    /// GL entirely so the main thread is the sole context user during that
    /// window.  Accessed ONLY from the serial render queue — no lock needed.
    private static var fboMaintenanceActive: Bool = false

    let wrapper:   Live2DWrapper
    let glContext: EAGLContext

    // ── FBO state ────────────────────────────────────────────────────────────
    // Written only:
    //   • from recreateFramebufferOnMainThread() on main after the render queue
    //     is drained, OR
    //   • from the async publish block that runs on renderQueue after creation.
    // Read only from renderQueue. No extra lock needed because the drain
    // serialises writes before reads.
    private var fbo:       GLuint = 0
    private var colorRb:   GLuint = 0
    private var depthRb:   GLuint = 0
    private var fboWidth:  GLint  = 0
    private var fboHeight: GLint  = 0

    private let renderQueue = Live2DGLView.sharedRenderQueue

    private var disposed = false
    private var displayLink: CADisplayLink?
    private var paused: Bool = false

    private let vsyncCoalesceLock       = NSLock()
    private var renderPumpQueuedOrRunning = false
    private var pendingExtraVsync         = false


    // ── Init ─────────────────────────────────────────────────────────────────

    override init(frame: CGRect) {
        glContext = Live2DGLView.sharedContext
        wrapper   = Live2DWrapper()
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    private func setup() {
        isOpaque = false

        eaglLayer.isOpaque = false
        eaglLayer.drawableProperties = [
            kEAGLDrawablePropertyRetainedBacking: false,
            kEAGLDrawablePropertyColorFormat:     kEAGLColorFormatRGBA8
        ]

        renderQueue.async { [weak self] in
            self?.makeContextCurrent()
            self?.wrapper.onSurfaceCreated()
        }

        let link = CADisplayLink(target: self, selector: #selector(renderFrame))
        link.add(to: .main, forMode: .common)
        displayLink = link

        isMultipleTouchEnabled = false
    }

    // ── Context helpers ───────────────────────────────────────────────────────

    private func makeContextCurrent() {
        if EAGLContext.current() !== glContext { EAGLContext.setCurrent(glContext) }
    }

    func setRenderingPaused(_ value: Bool) {
        paused = value
        displayLink?.isPaused = value
    }

    // ── FBO lifecycle — MAIN THREAD ONLY ─────────────────────────────────────
    //
    // Sequence (all GL creation happens on the main thread):
    //   1. renderQueue.sync — drain in-flight GL, clear context on render thread,
    //      set fboMaintenanceActive=true so ALL views' pumps skip GL, zero handles.
    //   2. Main thread — ALL GL work: delete old objects, create color rb
    //      (renderbufferStorage MUST be on main — UIKit requirement), depth rb,
    //      and assemble FBO.  Safe because fboMaintenanceActive blocks every pump
    //      from every view, so no other GL runs concurrently.
    //   3. renderQueue.async — install handles, clear fboMaintenanceActive so
    //      pumps resume. No GL creation here — just bookkeeping.
    //
    // Why all-on-main instead of deferred depth/FBO to render queue:
    //   With a SHARED context the render queue may still run pumps from the OTHER
    //   view (whose fbo is still > 0) between step 2 and the render-queue async.
    //   Keeping everything on main while fboMaintenanceActive=true is the only
    //   way to guarantee the context is single-threaded during FBO creation.

    private func recreateFramebufferOnMainThread() {
        assert(Thread.isMainThread)
        guard !disposed else { return }

        // ── Step 1: drain render queue, block all pumps ───────────────────────
        var oldFb:  GLuint = 0
        var oldCrb: GLuint = 0
        var oldDrb: GLuint = 0

        renderQueue.sync { [glContext = self.glContext] in
            if EAGLContext.current() === glContext { EAGLContext.setCurrent(nil) }
            // Block ALL views' pumps until step 3 clears this flag.
            Live2DGLView.fboMaintenanceActive = true
            oldFb  = self.fbo;     self.fbo     = 0
            oldCrb = self.colorRb; self.colorRb = 0
            oldDrb = self.depthRb; self.depthRb = 0
            self.fboWidth  = 0
            self.fboHeight = 0
        }
        // After sync: render thread owns no context; fboMaintenanceActive=true
        // means every pump (including from the OTHER view) will return false
        // before making any GL call.  Safe to use the context on main.

        // ── Step 2: ALL GL work on main ───────────────────────────────────────
        EAGLContext.setCurrent(glContext)
        defer { EAGLContext.setCurrent(nil) }

        if oldFb  != 0 { glDeleteFramebuffers(1,  &oldFb)  }
        if oldCrb != 0 { glDeleteRenderbuffers(1, &oldCrb) }
        if oldDrb != 0 { glDeleteRenderbuffers(1, &oldDrb) }

        // Color renderbuffer (renderbufferStorage:fromDrawable: MUST be on main)
        var crb: GLuint = 0
        glGenRenderbuffers(1, &crb)
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), crb)
        let rbOk = glContext.renderbufferStorage(Int(GL_RENDERBUFFER), from: eaglLayer)
        guard rbOk else {
            glDeleteRenderbuffers(1, &crb)
            Live2DNativeLog.line("FBO: renderbufferStorage failed (layer not in window?)")
            renderQueue.async { Live2DGLView.fboMaintenanceActive = false }
            return
        }

        var w: GLint = 0, h: GLint = 0
        glGetRenderbufferParameteriv(GLenum(GL_RENDERBUFFER),
                                     GLenum(GL_RENDERBUFFER_WIDTH),  &w)
        glGetRenderbufferParameteriv(GLenum(GL_RENDERBUFFER),
                                     GLenum(GL_RENDERBUFFER_HEIGHT), &h)
        guard w > 0 && h > 0 else {
            glDeleteRenderbuffers(1, &crb)
            renderQueue.async { Live2DGLView.fboMaintenanceActive = false }
            return
        }

        // Depth renderbuffer
        var drb: GLuint = 0
        glGenRenderbuffers(1, &drb)
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), drb)
        glRenderbufferStorage(GLenum(GL_RENDERBUFFER),
                              GLenum(GL_DEPTH_COMPONENT16), w, h)

        // Assemble framebuffer
        var fb: GLuint = 0
        glGenFramebuffers(1, &fb)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), fb)
        glFramebufferRenderbuffer(GLenum(GL_FRAMEBUFFER),
                                  GLenum(GL_COLOR_ATTACHMENT0),
                                  GLenum(GL_RENDERBUFFER), crb)
        glFramebufferRenderbuffer(GLenum(GL_FRAMEBUFFER),
                                  GLenum(GL_DEPTH_ATTACHMENT),
                                  GLenum(GL_RENDERBUFFER), drb)

        let status = glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER))
        guard status == GLenum(GL_FRAMEBUFFER_COMPLETE) else {
            Live2DNativeLog.line("FBO incomplete: status=0x\(String(status, radix:16))")
            var f = fb, c = crb, d = drb
            glDeleteFramebuffers(1,  &f)
            glDeleteRenderbuffers(1, &c)
            glDeleteRenderbuffers(1, &d)
            renderQueue.async { Live2DGLView.fboMaintenanceActive = false }
            return
        }
        // context released here by `defer { EAGLContext.setCurrent(nil) }`

        // ── Step 3: publish handles + unblock pumps on render queue ──────────
        // FBO is fully built; this async block just stores the IDs and re-enables
        // rendering.  No GL creation happens here.
        renderQueue.async { [weak self] in
            Live2DGLView.fboMaintenanceActive = false   // resume all pumps
            guard let self = self, !self.disposed else {
                // View gone — delete the objects we built.
                EAGLContext.setCurrent(Live2DGLView.sharedContext)
                var f = fb, c = crb, d = drb
                glDeleteFramebuffers(1,  &f)
                glDeleteRenderbuffers(1, &c)
                glDeleteRenderbuffers(1, &d)
                return
            }
            self.makeContextCurrent()
            // If a rapid successive recreate already installed a newer FBO, drop ours.
            guard self.fbo == 0 else {
                EAGLContext.setCurrent(Live2DGLView.sharedContext)
                var f = fb, c = crb, d = drb
                glDeleteFramebuffers(1,  &f)
                glDeleteRenderbuffers(1, &c)
                glDeleteRenderbuffers(1, &d)
                return
            }
            self.fbo      = fb
            self.colorRb  = crb
            self.depthRb  = drb
            self.fboWidth  = w
            self.fboHeight = h
        }
    }

    // ── View lifecycle ────────────────────────────────────────────────────────

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        recreateFramebufferOnMainThread()
        renderQueue.async { [weak self] in
            guard let self = self, !self.disposed else { return }
            self.makeContextCurrent()
            self.bindFBO()
            self.wrapper.tryCompletePendingRendererInstall()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let s = contentScaleFactor
        let w = Int32(bounds.width  * s)
        let h = Int32(bounds.height * s)
        if w > 0 && h > 0 {
            recreateFramebufferOnMainThread()
            renderQueue.async { [weak self] in
                guard let self = self, !self.disposed else { return }
                self.makeContextCurrent()
                self.bindFBO()
                self.wrapper.onSurfaceChanged(width: w, height: h)
            }
        }
    }

    // ── Render-thread FBO helpers (pure GL, no UIKit) ─────────────────────────

    /// Bind our FBO (or framebuffer 0 when not yet created). Always produces a
    /// known GL state: if fbo==0, framebuffer 0 has no color attachment, which
    /// causes Live2DCurrentFramebufferHasColorAttachment() to return NO and
    /// correctly defer renderer installation until the FBO is ready.
    private func bindFBO() {
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), fbo)
    }

    private func presentColorRenderbuffer() {
        guard colorRb != 0 else { return }
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), colorRb)
        _ = glContext.presentRenderbuffer(Int(GL_RENDERBUFFER))
    }

    // ── Async wrapper API ─────────────────────────────────────────────────────

    func loadModelAsync(modelDir: String, fileName: String,
                        completion: @escaping (Bool) -> Void) {
        renderQueue.async { [weak self] in
            guard let self = self, !self.disposed else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            self.makeContextCurrent()
            self.bindFBO()
            let ok = self.wrapper.loadModel(modelDir: modelDir, fileName: fileName)
            if ok {
                self.bindFBO()
                self.wrapper.tryCompletePendingRendererInstall()
            }
            DispatchQueue.main.async { completion(ok) }
        }
    }

    func unloadModelAsync() {
        renderQueue.async { [weak self] in
            guard let self = self, !self.disposed else { return }
            self.makeContextCurrent()
            self.wrapper.unloadModel()
        }
    }

    func startMotion(group: String, index: Int32, priority: Int32) {
        renderQueue.async { [weak self] in
            guard let self = self, !self.disposed else { return }
            self.makeContextCurrent()
            self.wrapper.startMotion(group: group, index: index, priority: priority)
        }
    }

    func setExpression(index: Int32) {
        renderQueue.async { [weak self] in
            guard let self = self, !self.disposed else { return }
            self.makeContextCurrent()
            self.wrapper.setExpression(index: index)
        }
    }

    func setParameter(parameterId: String, value: Float) {
        renderQueue.async { [weak self] in
            guard let self = self, !self.disposed else { return }
            self.makeContextCurrent()
            self.wrapper.setParameter(parameterId: parameterId, value: value)
        }
    }

    func setMotionSpeed(_ speed: Float) {
        renderQueue.async { [weak self] in
            guard let self = self, !self.disposed else { return }
            self.wrapper.setMotionSpeed(speed)
        }
    }

    // ── Frame pump ────────────────────────────────────────────────────────────
    //
    // CADisplayLink fires on main; vsyncs coalesce into at most one queued
    // pump on renderQueue (no unbounded async backlog, no dropped frames).

    private func scheduleRenderPumpFromAnyThread() {
        vsyncCoalesceLock.lock()
        if renderPumpQueuedOrRunning {
            pendingExtraVsync = true
            vsyncCoalesceLock.unlock()
            return
        }
        renderPumpQueuedOrRunning = true
        vsyncCoalesceLock.unlock()
        renderQueue.async { [weak self] in self?.runDisplayLinkPump() }
    }

    @objc private func renderFrame() {
        if !paused { scheduleRenderPumpFromAnyThread() }
    }

    private func runDisplayLinkPump() {
        if !disposed && !paused { _ = drawAndPresentOneFrame() }
        vsyncCoalesceLock.lock()
        renderPumpQueuedOrRunning = false
        let tail = pendingExtraVsync
        pendingExtraVsync = false
        vsyncCoalesceLock.unlock()
        if tail && !disposed && !paused { scheduleRenderPumpFromAnyThread() }
    }

    private func drawAndPresentOneFrame() -> Bool {
        // FBO not yet created, recreate in progress, OR another view currently
        // has the shared context on the main thread — skip silently.
        guard fbo != 0 && fboWidth > 0 && !Live2DGLView.fboMaintenanceActive else { return false }

        makeContextCurrent()
        bindFBO()

        // Give Cubism a chance to install a deferred renderer.
        wrapper.tryCompletePendingRendererInstall()

        // Re-bind after tryComplete (Cubism may have switched FBOs internally).
        bindFBO()

        // Sanity-check color attachment.
        var attachedRb: GLint = 0
        glGetFramebufferAttachmentParameteriv(
            GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0),
            GLenum(GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME), &attachedRb)
        if attachedRb == 0 {
            wrapper.onFramebufferColorAttachmentMissing()
            return false
        }

        wrapper.onDrawFrame()

        // Cubism Draw() leaves its own FBO bound. Restore ours before present.
        bindFBO()
        presentColorRenderbuffer()
        return true
    }

    // ── Touch forwarding ──────────────────────────────────────────────────────

    override func touchesBegan(_ t: Set<UITouch>, with e: UIEvent?) {
        super.touchesBegan(t, with: e); forwardTouches(t, ended: false, cancelled: false)
    }
    override func touchesMoved(_ t: Set<UITouch>, with e: UIEvent?) {
        super.touchesMoved(t, with: e); forwardTouches(t, ended: false, cancelled: false)
    }
    override func touchesEnded(_ t: Set<UITouch>, with e: UIEvent?) {
        super.touchesEnded(t, with: e); forwardTouches(t, ended: true,  cancelled: false)
    }
    override func touchesCancelled(_ t: Set<UITouch>, with e: UIEvent?) {
        super.touchesCancelled(t, with: e); forwardTouches(t, ended: true, cancelled: true)
    }

    private func forwardTouches(_ touches: Set<UITouch>, ended: Bool, cancelled: Bool) {
        guard let t = touches.first else { return }
        let pt = t.location(in: self)
        let s  = contentScaleFactor
        let x  = Float(pt.x * s), y = Float(pt.y * s)
        let isDown = !ended && !cancelled && t.phase == .began
        renderQueue.async { [weak self] in
            guard let self = self, !self.disposed else { return }
            self.makeContextCurrent()
            if ended || cancelled     { self.wrapper.touchEnded(x: x, y: y) }
            else if isDown            { self.wrapper.touchBegan(x: x, y: y) }
            else                      { self.wrapper.touchMoved(x: x, y: y) }
        }
    }

    // ── Teardown ──────────────────────────────────────────────────────────────

    deinit {
        displayLink?.invalidate()
        displayLink = nil
        // Drain renderQueue so no in-flight blocks access the wrapper/context
        // after we tear it down. Safe: nothing on renderQueue blocks main.
        renderQueue.sync {
            disposed = true
            makeContextCurrent()
            wrapper.dispose()
            var f = fbo, c = colorRb, d = depthRb
            if f != 0 { glDeleteFramebuffers(1,  &f) }
            if c != 0 { glDeleteRenderbuffers(1, &c) }
            if d != 0 { glDeleteRenderbuffers(1, &d) }
            EAGLContext.setCurrent(nil)
        }
    }
}
