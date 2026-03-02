import 'dart:async';
import 'package:flutter/services.dart';
import 'loop_audio_state.dart';

/// A player for sample-accurate gapless audio looping on iOS.
///
/// Uses [MethodChannel] for commands and [EventChannel] for state/error/route events.
///
/// All methods and getters may throw [PlatformException] if the native engine
/// returns an error.
///
/// Note: This plugin uses a single shared [MethodChannel] — instantiating
/// multiple [LoopAudioPlayer] objects will result in cross-talk. Use a single
/// instance per application.
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

  bool _isDisposed = false;

  /// Creates a new [LoopAudioPlayer].
  LoopAudioPlayer() {
    _events = _eventChannel
        .receiveBroadcastStream()
        .cast<Map<Object?, Object?>>();
  }

  void _checkNotDisposed() {
    if (_isDisposed) throw StateError('LoopAudioPlayer has been disposed.');
  }

  /// Stream of [PlayerState] changes pushed from the native layer.
  Stream<PlayerState> get stateStream {
    _checkNotDisposed();
    return _events
        .where((e) => e['type'] == 'stateChange')
        .map((e) => _parseState(e['state'] as String? ?? 'idle'));
  }

  /// Stream of error messages pushed from the native layer.
  Stream<String> get errorStream {
    _checkNotDisposed();
    return _events
        .where((e) => e['type'] == 'error')
        .map((e) => e['message'] as String? ?? 'Unknown error');
  }

  /// Stream of [RouteChangeEvent]s pushed when the audio route changes
  /// (e.g. headphones unplugged).
  Stream<RouteChangeEvent> get routeChangeStream {
    _checkNotDisposed();
    return _events
        .where((e) => e['type'] == 'routeChange')
        .map((e) => RouteChangeEvent(_parseReason(e['reason'] as String? ?? '')));
  }

  /// Stream of [BpmResult] emitted automatically after each successful load.
  ///
  /// Fires once per load, shortly after [stateStream] emits [PlayerState.ready],
  /// when the background beat-tracking analysis completes.
  ///
  /// Returns `bpm: 0.0` if the audio is shorter than 2 seconds or silent.
  Stream<BpmResult> get bpmStream {
    _checkNotDisposed();
    return _events
        .where((e) => e['type'] == 'bpmDetected')
        .map((e) => BpmResult.fromMap(e));
  }

  /// Loads an audio file from a Flutter asset key (e.g. `'assets/loop.wav'`).
  /// The native layer resolves the asset key to an absolute path using the
  /// Flutter asset registry.
  ///
  /// Throws [PlatformException] on native error.
  Future<void> load(String assetPath) async {
    _checkNotDisposed();
    await _channel.invokeMethod<void>('loadAsset', {'assetKey': assetPath});
  }

  /// Loads an audio file from an absolute file system path.
  ///
  /// Throws [PlatformException] on native error.
  Future<void> loadFromFile(String filePath) async {
    _checkNotDisposed();
    await _channel.invokeMethod<void>('load', {'path': filePath});
  }

  /// Starts looping playback from the beginning (or current loop region start).
  Future<void> play() async {
    _checkNotDisposed();
    await _channel.invokeMethod<void>('play');
  }

  /// Pauses playback. Call [resume] to continue from the same position.
  Future<void> pause() async {
    _checkNotDisposed();
    await _channel.invokeMethod<void>('pause');
  }

  /// Resumes paused playback.
  Future<void> resume() async {
    _checkNotDisposed();
    await _channel.invokeMethod<void>('resume');
  }

  /// Stops playback and resets the playback position.
  Future<void> stop() async {
    _checkNotDisposed();
    await _channel.invokeMethod<void>('stop');
  }

  /// Sets the loop region in seconds. Both [start] and [end] are inclusive.
  ///
  /// When set, only the audio between [start] and [end] will loop.
  /// Activates Mode B or D on the native engine.
  ///
  /// Throws [PlatformException] on native error.
  Future<void> setLoopRegion(double start, double end) async {
    _checkNotDisposed();
    if (start < 0) throw ArgumentError.value(start, 'start', 'must be >= 0');
    if (end <= start) throw ArgumentError('end ($end) must be greater than start ($start)');
    await _channel.invokeMethod<void>('setLoopRegion', {'start': start, 'end': end});
  }

  /// Sets the crossfade duration in seconds.
  ///
  /// A value of `0.0` (the default) disables crossfade and uses the lowest-latency
  /// `.loops` scheduling path (Mode A or B). Values greater than `0.0` activate
  /// the dual-node crossfade system (Mode C or D).
  Future<void> setCrossfadeDuration(double seconds) async {
    _checkNotDisposed();
    await _channel.invokeMethod<void>('setCrossfadeDuration', {'duration': seconds});
  }

  /// Sets the playback volume. Range: 0.0 (silent) to 1.0 (full volume).
  Future<void> setVolume(double volume) async {
    _checkNotDisposed();
    if (volume < 0.0 || volume > 1.0) {
      throw ArgumentError.value(volume, 'volume', 'must be between 0.0 and 1.0');
    }
    await _channel.invokeMethod<void>('setVolume', {'volume': volume});
  }

  /// Sets the stereo pan position.
  ///
  /// [pan] is in [-1.0, 1.0]:
  /// - `-1.0` = full left
  /// - `0.0`  = centre (default)
  /// - `1.0`  = full right
  ///
  /// Values outside the range are clamped to [-1.0, 1.0].
  /// Takes effect immediately. Persists across loads.
  ///
  /// Throws [PlatformException] on native error.
  Future<void> setPan(double pan) async {
    _checkNotDisposed();
    await _channel.invokeMethod<void>('setPan', {'pan': pan.clamp(-1.0, 1.0)});
  }

  /// Seeks to [seconds] within the loaded file.
  ///
  /// Note: seeking during `.loops` mode causes a brief reschedule on the native
  /// side. The next loop boundary will restart from the loop region start, not
  /// the seek position.
  ///
  /// Throws [PlatformException] on native error.
  Future<void> seek(double seconds) async {
    _checkNotDisposed();
    await _channel.invokeMethod<void>('seek', {'position': seconds});
  }

  /// Returns the total duration of the loaded file.
  Future<Duration> get duration async {
    _checkNotDisposed();
    final secs = await _channel.invokeMethod<double>('getDuration') ?? 0.0;
    return Duration(milliseconds: (secs * 1000).round());
  }

  /// Returns the current playback position in seconds.
  Future<double> get currentPosition async {
    _checkNotDisposed();
    return await _channel.invokeMethod<double>('getCurrentPosition') ?? 0.0;
  }

  /// Releases all native resources. This instance cannot be used after calling dispose.
  Future<void> dispose() async {
    _isDisposed = true;
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
