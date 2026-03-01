
import 'flutter_gapless_loop_platform_interface.dart';

class FlutterGaplessLoop {
  Future<String?> getPlatformVersion() {
    return FlutterGaplessLoopPlatform.instance.getPlatformVersion();
  }
}
