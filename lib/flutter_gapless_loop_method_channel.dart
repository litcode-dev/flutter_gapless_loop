import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'flutter_gapless_loop_platform_interface.dart';

/// An implementation of [FlutterGaplessLoopPlatform] that uses method channels.
class MethodChannelFlutterGaplessLoop extends FlutterGaplessLoopPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('flutter_gapless_loop');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }
}
