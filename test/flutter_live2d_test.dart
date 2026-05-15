import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_live2d/flutter_live2d.dart';
import 'package:flutter_live2d/flutter_live2d_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _MockFlutterLive2dPlatform
    with MockPlatformInterfaceMixin
    implements FlutterLive2dPlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');

  @override
  Future<bool> loadModel({
    required int viewId,
    required String modelDir,
    required String modelFileName,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> unloadModel({required int viewId}) => throw UnimplementedError();

  @override
  Future<void> setRenderingPaused({
    required int viewId,
    required bool paused,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> setExpression({required int viewId, required int index}) =>
      throw UnimplementedError();

  @override
  Future<void> setParameter({
    required int viewId,
    required String parameterId,
    required double value,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> startMotion({
    required int viewId,
    required String group,
    required int index,
    int priority = 2,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> setMotionSpeed({required int viewId, required double speed}) =>
      throw UnimplementedError();

  @override
  Future<String> getTempDirectory() => Future.value('/tmp');
}

void main() {
  test('$MethodChannelFlutterLive2d is the default instance', () {
    expect(
      FlutterLive2dPlatform.instance,
      isInstanceOf<MethodChannelFlutterLive2d>(),
    );
  });

  test('Live2D.getPlatformVersion delegates to the platform interface',
      () async {
    final fake = _MockFlutterLive2dPlatform();
    FlutterLive2dPlatform.instance = fake;
    expect(await Live2D.getPlatformVersion(), '42');
  });
}
