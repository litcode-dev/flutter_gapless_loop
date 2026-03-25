import 'package:flutter/services.dart';
import 'file_utils_base.dart';

class FileUtilsWeb implements FileUtils {
  final _channel = const MethodChannel('flutter_gapless_loop');

  @override
  Future<void> loadFromBytes(String playerId, Uint8List bytes, String extension, Future<void> Function(String path) loadFromFile) async {
    // On web, we send bytes directly via MethodChannel
    await _channel.invokeMethod<void>('loadFromBytes', {
      'playerId': playerId,
      'bytes': bytes,
      'extension': extension,
    });
  }
}

FileUtils getFileUtils() => FileUtilsWeb();
