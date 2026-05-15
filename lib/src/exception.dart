part of '../flutter_live2d.dart';

// ---------------------------------------------------------------------------
// Public exceptions
// ---------------------------------------------------------------------------

/// Error thrown by every command on a [Live2DViewController].
///
/// All native errors are normalized into this type so callers can branch on a
/// stable [code] without inspecting raw [PlatformException]s.
///
/// ### Common codes
///
/// | Code | Meaning |
/// | --- | --- |
/// | `VIEW_NOT_ATTACHED` | Method was called before the [Live2DView] mounted. Await [Live2DViewController.whenAttached] first. |
/// | `VIEW_NOT_FOUND` | The native view was already disposed. |
/// | `INVALID_ARGS` | One of the arguments was missing or malformed. |
/// | `LOAD_FAILED` | The native side rejected the model (corrupt, missing files, …). |
/// | `NATIVE_ERROR` | Generic native failure with a more specific [message]. |
/// | `CONTROLLER_DISPOSED` | The Dart-side controller has already been disposed. |
class Live2DException implements Exception {
  /// Creates an exception with a stable [code] and a human-readable [message].
  ///
  /// [details] mirrors [PlatformException.details] when the error originated
  /// from the platform channel.
  Live2DException(this.code, this.message, {this.details});

  /// Stable, machine-readable error code. See the table in the class doc for
  /// the values produced by this plugin.
  final String code;

  /// Human-readable description, suitable for logging or debugging. Not
  /// localized — do not show directly to end users.
  final String message;

  /// Extra payload forwarded from the platform channel, when applicable.
  /// Usually `null`.
  final Object? details;

  @override
  String toString() => 'Live2DException($code): $message';
}

// ---------------------------------------------------------------------------
// Top-level utilities
// ---------------------------------------------------------------------------

/// Static utility namespace for plugin-level calls that aren't tied to a
/// specific [Live2DView].
abstract class Live2D {
  /// Returns the host platform's version string (e.g. `"Android 14"`,
  /// `"iOS 17.4"`).
  ///
  /// Useful as a smoke test that the plugin is wired up correctly. Returns
  /// `null` if the platform fails to provide a value.
  static Future<String?> getPlatformVersion() =>
      FlutterLive2dPlatform.instance.getPlatformVersion();
}
