import 'package:flutter/services.dart';

import 'loop_audio_player.dart';

/// A group controller that starts multiple [LoopAudioPlayer] instances
/// simultaneously with sample-accurate synchronisation.
///
/// On iOS the native layer schedules every player to begin at the same
/// `AVAudioTime` (derived from `mach_absolute_time() + lookahead`).
/// On Android every player's write thread waits until the same
/// `SystemClock.uptimeMillis()` target before writing the first chunk.
///
/// ## Example
///
/// ```dart
/// final drums  = LoopAudioPlayer();
/// final bass   = LoopAudioPlayer();
/// await drums.loadFromFile('/path/drums.wav');
/// await bass.loadFromFile('/path/bass.wav');
///
/// final group = LoopSyncGroup([drums, bass]);
/// await group.playAll();
/// ```
class LoopSyncGroup {
  static const _channel = MethodChannel('flutter_gapless_loop');

  /// The players managed by this group.
  final List<LoopAudioPlayer> players;

  /// Creates a sync group containing [players].
  ///
  /// All players must be in [PlayerState.ready] or [PlayerState.stopped] when
  /// [playAll] is called.
  const LoopSyncGroup(this.players);

  /// Starts all [players] simultaneously.
  ///
  /// [lookahead] is the scheduling window ahead of "now". A value of 50 ms
  /// gives the native layer enough time to schedule all buffers before the
  /// target time fires. Increase this on slower devices if you experience
  /// mis-aligned starts.
  ///
  /// Throws [PlatformException] if any player is not ready to play, or if
  /// the native layer fails to schedule playback.
  Future<void> playAll({
    Duration lookahead = const Duration(milliseconds: 50),
  }) async {
    if (players.isEmpty) return;
    final playerIds = players.map((p) => p.playerId).toList();
    await _channel.invokeMethod<void>('syncPlay', {
      'playerIds':     playerIds,
      'lookaheadMs':   lookahead.inMilliseconds,
    });
  }

  /// Pauses all players immediately (not synchronised — use individual
  /// [LoopAudioPlayer.pause] calls for independent control).
  Future<void> pauseAll() async {
    for (final p in players) {
      await p.pause();
    }
  }

  /// Stops all players.
  Future<void> stopAll() async {
    for (final p in players) {
      await p.stop();
    }
  }
}
