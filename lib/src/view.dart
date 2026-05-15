part of '../flutter_live2d.dart';

/// Widget that embeds a Live2D model rendered via OpenGL.
///
/// Mount one [Live2DView] per [Live2DViewController]. Multiple views can
/// coexist on the same page — on Android they share a single render thread
/// and EGL context internally; on iOS each view gets its own GL context.
///
/// The widget is a thin host: all interaction happens through [controller].
/// Listen to [controller] (it is a `ValueListenable<Live2DViewState>`) to
/// react to lifecycle, loading and error events.
class Live2DView extends StatelessWidget {
  /// Creates a [Live2DView].
  const Live2DView({super.key, this.controller});

  /// Controller bound to this view. Pass the same instance to control the
  /// model from outside the widget tree.
  ///
  /// May be `null` for a view without external control (rendering only),
  /// although typically you will want a controller to load a model.
  final Live2DViewController? controller;

  @override
  Widget build(BuildContext context) {
    return _Live2DViewImpl(controller: controller);
  }
}

// ---------------------------------------------------------------------------
// Internal stateful implementation
// ---------------------------------------------------------------------------

/// Internal `StatefulWidget` that bridges the public [Live2DView] to the
/// platform view. Kept private so users only see [Live2DView].
class _Live2DViewImpl extends StatefulWidget {
  const _Live2DViewImpl({this.controller});

  final Live2DViewController? controller;

  @override
  State<_Live2DViewImpl> createState() => _Live2DViewImplState();
}

class _Live2DViewImplState extends State<_Live2DViewImpl> {
  /// View type registered with the native side. Must match the value used
  /// when registering the platform view factory in
  /// `FlutterLive2dPlugin` on Android / iOS.
  static const String _viewType = 'live2d_view';

  /// Forwards the platform view id to the bound controller, driving the
  /// `detached → attached` transition.
  void _handlePlatformViewCreated(int id) {
    widget.controller?._attach(id);
  }

  @override
  void dispose() {
    widget.controller?._detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (Platform.isAndroid) {
      return PlatformViewLink(
        viewType: _viewType,
        surfaceFactory: (context, controller) {
          return AndroidViewSurface(
            controller: controller as AndroidViewController,
            gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
            hitTestBehavior: PlatformViewHitTestBehavior.opaque,
          );
        },
        onCreatePlatformView: (params) {
          final controller = PlatformViewsService.initExpensiveAndroidView(
            id: params.id,
            viewType: _viewType,
            layoutDirection: TextDirection.ltr,
            creationParams: null,
            creationParamsCodec: const StandardMessageCodec(),
            onFocus: () => params.onFocusChanged(true),
          );
          controller.addOnPlatformViewCreatedListener((id) {
            params.onPlatformViewCreated(id);
            _handlePlatformViewCreated(id);
          });
          controller.create();
          return controller;
        },
      );
    }

    if (Platform.isIOS) {
      return UiKitView(
        viewType: _viewType,
        layoutDirection: TextDirection.ltr,
        creationParams: null,
        creationParamsCodec: const StandardMessageCodec(),
        onPlatformViewCreated: _handlePlatformViewCreated,
        gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
        hitTestBehavior: PlatformViewHitTestBehavior.opaque,
      );
    }

    return const Center(
      child: Text('Live2D is not supported on this platform.'),
    );
  }
}
