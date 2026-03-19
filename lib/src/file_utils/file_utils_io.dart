import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'file_utils_base.dart';

class FileUtilsIo implements FileUtils {
  static final _random = Random();

  @override
  Future<void> loadFromBytes(String playerId, Uint8List bytes, String extension, Future<void> Function(String path) loadFromFile) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final nonce = _random.nextInt(0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
    final tmp = File(
        '${Directory.systemTemp.path}/flutter_gapless_${timestamp}_$nonce.$extension');
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      await loadFromFile(tmp.path);
    } finally {
      if (await tmp.exists()) await tmp.delete();
    }
  }
}

FileUtils getFileUtils() => FileUtilsIo();
