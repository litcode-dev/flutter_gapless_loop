import 'dart:async';
import 'package:flutter/services.dart';
import 'loop_audio_state.dart';

/// A player for sample-accurate gapless audio looping on iOS.
///
/// Uses [MethodChannel] for commands and [EventChannel] for state/error/route events.
///
/// Basic usage:
/// ```dart
/// final player = LoopAudioPlayer();
/// await player.loadFromFile('/path/to/audio.wav');
/// await player.play();
/// ```
///
/// Dispose when done to release native resources:
/// ```dart
/// await player.dispose();
/// ```
class LoopAudioPlayer {
  static const _channel = MethodChannel('flutter_gapless_loop');
  static const _eventChannel = EventChannel('flutter_gapless_loop/events');

  late final Stream<Map<Object?, Object?>> _events;

  /// Creates a new [LoopAudioPlayer].
  LoopAudioPlayer() {
    _events = _eventChannel
        .receiveBroadcastStream()
        .cast<Map<Object?, Object?>>();
  }

  /// Stream of [PlayerState] changes pushed from the native layer.
  Stream<PlayerState> get stateStream => _events
      .where((e) => e['type'] == 'stateChange')
      .map((e) => _parseState(e['state'] as String? ?? 'idle'));

  /// Stream of error messages pushed from the native layer.
  Stream<String> get errorStream => _events
      .where((e) => e['type'] == 'error')
      .map((e) => e['message'] as String? ?? 'Unknown error');

  /// Stream of [RouteChangeEvent]s pushed when the audio route changes
  /// (e.g. headphones unplugged).
  Stream<RouteChangeEvent> get routeChangeStream => _events
      .where((e) => e['type'] == 'routeChange')
      .map((e) => RouteChangeEvent(_parseReason(e['reason'] as String? ?? '')));

  /// Loads an audio file from a Flutter asset path.
  ///
  /// The native layer expects an absolute file system path. Asset resolution
  /// (mapping asset keys to paths) is handled on the native side via the
  /// Flutter asset registry.
  Future<void> load(String assetPath) async {
    await _channel.invokeMethod<void>('load', {'path': assetPath});
  }

  /// Loads an audio file from an absolute file system path.
  Future<void> loadFromFile(String filePath) async {
    await _channel.invokeMethod<void>('load', {'path': filePath});
  }

  /// Starts looping playback from the beginning (or current loop region start).
  Future<void> play() async {
    await _channel.invokeMethod<void>('play');
  }

  /// Pauses playback. Call [resume] to continue from the same position.
  Future<void> pause() async {
    await _channel.invokeMethod<void>('pause');
  }

  /// Resumes paused playback.
  Future<void> resume() async {
    await _channel.invokeMethod<void>('resume');
  }

  /// Stops playback and resets the playback position.
  Future<void> stop() async {
    await _channel.invokeMethod<void>('stop');
  }

  /// Sets the loop region in seconds. Both [start] and [end] are inclusive.
  ///
  /// When set, only the audio between [start] and [end] will loop.
  /// Activates Mode B or D on the native engine.
  Future<void> setLoopRegion(double start, double end) async {
    await _channel.invokeMethod<void>('setLoopRegion', {'start': start, 'end': end});
  }

  /// Sets the crossfade duration in seconds.
  ///
  /// A value of `0.0` (the default) disables crossfade and uses the lowest-latency
  /// `.loops` scheduling path (Mode A or B). Values greater than `0.0` activate
  /// the dual-node crossfade system (Mode C or D).
  Future<void> setCrossfadeDuration(double seconds) async {
    await _channel.invokeMethod<void>('setCrossfadeDuration', {'duration': seconds});
  }

  /// Sets the playback volume. Range: 0.0 (silent) to 1.0 (full volume).
  Future<void> setVolume(double volume) async {
    await _channel.invokeMethod<void>('setVolume', {'volume': volume});
  }

  /// Seeks to [seconds] within the loaded file.
  ///
  /// Note: seeking during `.loops` mode causes a brief reschedule on the native
  /// side. The next loop boundary will restart from [loopStart], not the seek position.
  Future<void> seek(double seconds) async {
    await _channel.invokeMethod<void>('seek', {'position': seconds});
  }

  /// Returns the total duration of the loaded file.
  Future<Duration> get duration async {
    final secs = await _channel.invokeMethod<double>('getDuration') ?? 0.0;
    return Duration(milliseconds: (secs * 1000).round());
  }

  /// Returns the current playback position in seconds.
  Future<double> get currentPosition async {
    return await _channel.invokeMethod<double>('getCurrentPosition') ?? 0.0;
  }

  /// Releases all native resources. This instance cannot be used after calling dispose.
  Future<void> dispose() async {
    await _channel.invokeMethod<void>('dispose');
  }

  PlayerState _parseState(String s) => switch (s) {
        'loading' => PlayerState.loading,
        'ready'   => PlayerState.ready,
        'playing' => PlayerState.playing,
        'paused'  => PlayerState.paused,
        'stopped' => PlayerState.stopped,
        'error'   => PlayerState.error,
        _         => PlayerState.idle,
      };

  RouteChangeReason _parseReason(String r) => switch (r) {
        'headphonesUnplugged' => RouteChangeReason.headphonesUnplugged,
        'categoryChange'      => RouteChangeReason.categoryChange,
        _                     => RouteChangeReason.unknown,
      };
}
