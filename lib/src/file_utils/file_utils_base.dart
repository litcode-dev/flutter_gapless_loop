import 'dart:typed_data';

/// Abstracted file operations for LoopAudioPlayer.
abstract class FileUtils {
  Future<void> loadFromBytes(String playerId, Uint8List bytes, String extension, Future<void> Function(String path) loadFromFile);
}

FileUtils getFileUtils() => throw UnsupportedError('Cannot create FileUtils');
