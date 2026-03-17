import 'dart:async';
import 'package:flutter/services.dart';
import 'loop_audio_player.dart';

/// Provides sample-accurate simultaneous control of multiple [LoopAudioPlayer]
/// instances.
///
/// On iOS, uses [AVAudioTime] for sample-accurate scheduling.
/// On Android, starts all write threads in rapid succession on a single thread.
/// On Windows, uses the same XAudio2 operation-set ID for atomic start.
class LoopSyncGroup {
  LoopSyncGroup._();

  static const _channel = MethodChannel('flutter_gapless_loop');

  /// Starts all [players] as close to simultaneously as possible.
  ///
  /// On iOS, uses AVAudioTime for sample-accurate scheduling.
  /// On Android, uses SystemClock.uptimeMillis for tight synchronisation.
  static Future<void> playAll(List<LoopAudioPlayer> players) async {
    if (players.isEmpty) return;
    final playerIds = players.map((p) => p.playerId).toList();
    await _channel.invokeMethod<void>('syncPlayAll', {'playerIds': playerIds});
  }

  /// Pauses all [players] simultaneously.
  static Future<void> pauseAll(List<LoopAudioPlayer> players) async {
    if (players.isEmpty) return;
    final playerIds = players.map((p) => p.playerId).toList();
    await _channel.invokeMethod<void>('syncPauseAll', {'playerIds': playerIds});
  }

  /// Stops all [players] simultaneously.
  static Future<void> stopAll(List<LoopAudioPlayer> players) async {
    if (players.isEmpty) return;
    final playerIds = players.map((p) => p.playerId).toList();
    await _channel.invokeMethod<void>('syncStopAll', {'playerIds': playerIds});
  }
}
