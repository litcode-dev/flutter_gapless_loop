import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gapless_loop/flutter_gapless_loop.dart';
import 'package:flutter_gapless_loop/flutter_gapless_loop_platform_interface.dart';
import 'package:flutter_gapless_loop/flutter_gapless_loop_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockFlutterGaplessLoopPlatform
    with MockPlatformInterfaceMixin
    implements FlutterGaplessLoopPlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final FlutterGaplessLoopPlatform initialPlatform = FlutterGaplessLoopPlatform.instance;

  test('$MethodChannelFlutterGaplessLoop is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelFlutterGaplessLoop>());
  });

  test('getPlatformVersion', () async {
    FlutterGaplessLoop flutterGaplessLoopPlugin = FlutterGaplessLoop();
    MockFlutterGaplessLoopPlatform fakePlatform = MockFlutterGaplessLoopPlatform();
    FlutterGaplessLoopPlatform.instance = fakePlatform;

    expect(await flutterGaplessLoopPlugin.getPlatformVersion(), '42');
  });
}
