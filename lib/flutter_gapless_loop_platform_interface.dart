import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'flutter_gapless_loop_method_channel.dart';

abstract class FlutterGaplessLoopPlatform extends PlatformInterface {
  /// Constructs a FlutterGaplessLoopPlatform.
  FlutterGaplessLoopPlatform() : super(token: _token);

  static final Object _token = Object();

  static FlutterGaplessLoopPlatform _instance = MethodChannelFlutterGaplessLoop();

  /// The default instance of [FlutterGaplessLoopPlatform] to use.
  ///
  /// Defaults to [MethodChannelFlutterGaplessLoop].
  static FlutterGaplessLoopPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [FlutterGaplessLoopPlatform] when
  /// they register themselves.
  static set instance(FlutterGaplessLoopPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
