package com.linh18nd.flutter_live2d

import android.content.res.AssetManager

object Live2DBridge {

    init {
        System.loadLibrary("flutter_live2d")
    }

    // Process-wide. Must be called once before any view is created.
    external fun nativeSetAssetManager(assetManager: AssetManager)

    // Per-view lifecycle. Each Live2DPlatformView holds its own handle.
    external fun nativeCreateView(): Long
    external fun nativeDestroyView(handle: Long)

    // GL surface callbacks (called on the view's render thread)
    external fun nativeOnSurfaceCreated(handle: Long)
    external fun nativeOnSurfaceDestroyed(handle: Long)
    external fun nativeOnSurfaceChanged(handle: Long, width: Int, height: Int)
    external fun nativeOnDrawFrame(handle: Long)

    // Model
    external fun nativeLoadModel(handle: Long, modelDir: String, modelFileName: String): Boolean
    external fun nativeUnloadModel(handle: Long)

    // Touch events
    external fun nativeOnTouchBegan(handle: Long, x: Float, y: Float)
    external fun nativeOnTouchMoved(handle: Long, x: Float, y: Float)
    external fun nativeOnTouchEnded(handle: Long, x: Float, y: Float)

    // Motion / expression control
    external fun nativeStartMotion(handle: Long, group: String, index: Int, priority: Int)
    external fun nativeSetExpression(handle: Long, index: Int)
    external fun nativeSetParameter(handle: Long, parameterId: String, value: Float)
    external fun nativeSetMotionSpeed(handle: Long, speed: Float)
}
