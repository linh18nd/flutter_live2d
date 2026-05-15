import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'flutter_live2d_platform_interface.dart';

/// Default platform implementation of [FlutterLive2dPlatform], routing every
/// call through the `flutter_live2d` [MethodChannel].
///
/// Behavioral notes that apply across calls:
///
/// * `viewId` identifies the native view created when a `Live2DView`
///   widget mounts. The native side uses it to look up the per-view state
///   (model, GL surface, …) and returns a `VIEW_NOT_FOUND` error if the
///   view has already been disposed.
/// * Native errors are surfaced as [PlatformException]s with the codes
///   listed in the [Live2DException] documentation. The Dart-side
///   [Live2DViewController] normalizes them into [Live2DException].
class MethodChannelFlutterLive2d extends FlutterLive2dPlatform {
  /// Underlying [MethodChannel]. Exposed for tests so they can install a
  /// mock handler; treat it as private otherwise.
  @visibleForTesting
  final methodChannel = const MethodChannel('flutter_live2d');

  @override
  Future<String?> getPlatformVersion() async {
    return methodChannel.invokeMethod<String>('getPlatformVersion');
  }

  @override
  Future<String> getTempDirectory() async {
    final path = await methodChannel.invokeMethod<String>('getTempDirectory');
    return path!;
  }

  @override
  Future<bool> loadModel({
    required int viewId,
    required String modelDir,
    required String modelFileName,
  }) async {
    final result = await methodChannel.invokeMethod<bool>('loadModel', {
      'viewId': viewId,
      'modelDir': modelDir,
      'modelFileName': modelFileName,
    });
    return result ?? false;
  }

  @override
  Future<void> unloadModel({required int viewId}) async {
    await methodChannel.invokeMethod<void>('unloadModel', {
      'viewId': viewId,
    });
  }

  @override
  Future<void> setRenderingPaused({
    required int viewId,
    required bool paused,
  }) async {
    await methodChannel.invokeMethod<void>('setRenderingPaused', {
      'viewId': viewId,
      'paused': paused,
    });
  }

  @override
  Future<void> startMotion({
    required int viewId,
    required String group,
    required int index,
    int priority = 2,
  }) async {
    await methodChannel.invokeMethod<void>('startMotion', {
      'viewId': viewId,
      'group': group,
      'index': index,
      'priority': priority,
    });
  }

  @override
  Future<void> setExpression({required int viewId, required int index}) async {
    await methodChannel.invokeMethod<void>('setExpression', {
      'viewId': viewId,
      'index': index,
    });
  }

  @override
  Future<void> setParameter({
    required int viewId,
    required String parameterId,
    required double value,
  }) async {
    await methodChannel.invokeMethod<void>('setParameter', {
      'viewId': viewId,
      'parameterId': parameterId,
      'value': value,
    });
  }

  @override
  Future<void> setMotionSpeed({
    required int viewId,
    required double speed,
  }) async {
    await methodChannel.invokeMethod<void>('setMotionSpeed', {
      'viewId': viewId,
      'speed': speed,
    });
  }
}
