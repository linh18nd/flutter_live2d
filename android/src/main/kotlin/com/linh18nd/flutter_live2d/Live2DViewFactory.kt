package com.linh18nd.flutter_live2d

import android.content.Context
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

class Live2DViewFactory(
    private val onCreated: (Int, Live2DPlatformView) -> Unit,
    private val onDisposed: (Int) -> Unit,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val view = Live2DPlatformView(context, viewId, onDisposed)
        onCreated(viewId, view)
        return view
    }
}
