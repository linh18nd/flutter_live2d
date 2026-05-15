import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'flutter_live2d_method_channel.dart';

/// Platform-specific implementation hook for `flutter_live2d`.
///
/// Federated plugin packages can subclass this and assign their instance to
/// [instance] to override how the Dart side talks to the native side. The
/// default implementation is [MethodChannelFlutterLive2d], which routes
/// every call through the `flutter_live2d` method channel.
///
/// End users of the plugin should not interact with this class directly —
/// use [Live2DViewController] and [Live2DView] from `flutter_live2d.dart`.
abstract class FlutterLive2dPlatform extends PlatformInterface {
  /// Constructs a new platform interface, registering the verification token
  /// used by [PlatformInterface.verifyToken].
  FlutterLive2dPlatform() : super(token: _token);

  /// Token used to ensure subclasses are passed through the official
  /// constructor chain (anti-spoofing for federated plugins).
  static final Object _token = Object();

  /// Currently active platform implementation. Defaults to
  /// [MethodChannelFlutterLive2d].
  static FlutterLive2dPlatform _instance = MethodChannelFlutterLive2d();

  /// Returns the active platform implementation.
  static FlutterLive2dPlatform get instance => _instance;

  /// Replaces the active platform implementation. Used by federated plugin
  /// packages and by tests that mock the platform layer.
  static set instance(FlutterLive2dPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// Returns the host platform's version string (e.g. `"Android 14"`).
  /// Used as a smoke test that the channel is wired up.
  Future<String?> getPlatformVersion() {
    throw UnimplementedError('getPlatformVersion() has not been implemented.');
  }

  /// Returns the platform's cache/temp directory path.
  Future<String> getTempDirectory() {
    throw UnimplementedError('getTempDirectory() has not been implemented.');
  }

  /// Loads a Live2D model into the native view identified by [viewId].
  ///
  /// [modelDir] must be an absolute filesystem directory; asset paths are
  /// resolved on the Dart side before reaching this method.
  ///
  /// [modelFileName] is the `.model3.json` entry file inside [modelDir].
  ///
  /// Resolves to `true` on success and `false` when the native side
  /// rejects the model (corrupt files, missing dependencies, …). Throws
  /// `PlatformException` for transport-level errors.
  Future<bool> loadModel({
    required int viewId,
    required String modelDir,
    required String modelFileName,
  }) {
    throw UnimplementedError('loadModel() has not been implemented.');
  }

  /// Unloads the model currently bound to [viewId] and frees its native
  /// resources. No-op if no model is loaded.
  Future<void> unloadModel({required int viewId}) {
    throw UnimplementedError('unloadModel() has not been implemented.');
  }

  /// Pauses or resumes the GL render loop for [viewId].
  ///
  /// While paused, the native model state is preserved but no frames are
  /// drawn — useful to save battery when the view is offscreen.
  Future<void> setRenderingPaused({
    required int viewId,
    required bool paused,
  }) {
    throw UnimplementedError('setRenderingPaused() has not been implemented.');
  }

  /// Plays a motion on [viewId].
  ///
  /// [group] is the motion group name from the model definition (empty
  /// string is the default group). [index] selects a motion within that
  /// group. [priority] follows Cubism conventions: `0=none`, `1=idle`,
  /// `2=normal`, `3=force`.
  Future<void> startMotion({
    required int viewId,
    required String group,
    required int index,
    int priority = 2,
  }) {
    throw UnimplementedError('startMotion() has not been implemented.');
  }

  /// Switches the active expression on [viewId] to the one at [index] in
  /// the model's expression list (0-based).
  Future<void> setExpression({required int viewId, required int index}) {
    throw UnimplementedError('setExpression() has not been implemented.');
  }

  /// Sets the model parameter [parameterId] on [viewId] to [value].
  ///
  /// [parameterId] follows Cubism naming, e.g. `"ParamAngleX"`. The valid
  /// range is defined by the model.
  Future<void> setParameter({
    required int viewId,
    required String parameterId,
    required double value,
  }) {
    throw UnimplementedError('setParameter() has not been implemented.');
  }

  /// Sets the motion playback speed multiplier for [viewId].
  ///
  /// `1.0` = normal speed, `2.0` = double speed, `0.5` = half speed,
  /// `0.0` = effectively paused. Must be ≥ 0.
  /// Physics, eye-blink and expression transitions are NOT affected.
  Future<void> setMotionSpeed({
    required int viewId,
    required double speed,
  }) {
    throw UnimplementedError('setMotionSpeed() has not been implemented.');
  }
}
