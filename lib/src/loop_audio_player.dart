import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'loop_audio_state.dart';
import 'file_utils/file_utils.dart';

/// A player for sample-accurate gapless audio looping on iOS, Android, macOS,
/// and Windows.
///
/// Uses [MethodChannel] for commands and [EventChannel] for state/error/route
/// events.
///
/// Multiple [LoopAudioPlayer] instances can run concurrently without cross-talk
/// — each is independently managed by the native layer.
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
  static const _channel      = MethodChannel('flutter_gapless_loop');
  static const _eventChannel = EventChannel('flutter_gapless_loop/events');

  // Shared broadcast stream — one subscription for all instances, each filters
  // by its own playerId so events don't cross-talk.
  static final Stream<Map<Object?, Object?>> _sharedEvents = _eventChannel
      .receiveBroadcastStream()
      .cast<Map<Object?, Object?>>();

  static int _nextId = 0;
  final String _playerId = 'loop_${_nextId++}';

  /// The unique identifier for this player instance.
  String get playerId => _playerId;

  late final Stream<Map<Object?, Object?>> _events;

  bool _isDisposed = false;

  double _localVolume = 1.0;
  double _localPan    = 0.0;

  // Stored so dispose() can remove the exact WeakReference object from the Set.
  late final WeakReference<LoopAudioPlayer> _weakSelf;

  // ── Hot-restart guard ──────────────────────────────────────────────────────
  // Dart statics are reset on hot restart; the native engine map is not.
  // Sending 'clearAll' on first construction removes any stale engines from the
  // previous session without affecting a normal cold start (clears an empty map).
  static bool _didClearAll = false;

  // ── GC-based cleanup ───────────────────────────────────────────────────────
  // Fires native 'dispose' if the player is GC'd without an explicit dispose().
  // Requires _instances to use WeakReference so strong refs don't block GC.
  static final Finalizer<String> _finalizer = Finalizer((playerId) {
    _channel.invokeMethod<void>('dispose', {'playerId': playerId});
  });

  /// Creates a new [LoopAudioPlayer].
  LoopAudioPlayer() {
    _weakSelf = WeakReference(this);
    _events   = _sharedEvents.where((e) => e['playerId'] == _playerId);
    LoopAudioMaster._instances.add(_weakSelf);
    _finalizer.attach(this, _playerId, detach: this);

    if (!_didClearAll) {
      _didClearAll = true;
      // Fire-and-forget: channel calls are serialised, so any subsequent call
      // on this channel will execute after clearAll completes on the native side.
      _channel.invokeMethod<void>('clearAll');
    }
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

  /// Stream of [AmplitudeEvent]s emitted ~20 times per second while playing.
  ///
  /// Each event carries the RMS and peak sample magnitude for the most recent
  /// audio buffer rendered by the native engine. Both values are in [0.0, 1.0].
  ///
  /// The stream is silent (no events) when the player is paused or stopped.
  Stream<AmplitudeEvent> get amplitudeStream {
    _checkNotDisposed();
    return _events
        .where((e) => e['type'] == 'amplitude')
        .map((e) => AmplitudeEvent.fromMap(e));
  }

  /// Loads an audio file from a Flutter asset key (e.g. `'assets/loop.wav'`).
  Future<void> load(String assetPath) async {
    _checkNotDisposed();
    await _channel.invokeMethod<void>(
        'loadAsset', {'playerId': _playerId, 'assetKey': assetPath});
  }

  /// Loads an audio file from an absolute file system path.
  Future<void> loadFromFile(String filePath) async {
    _checkNotDisposed();
    await _channel.invokeMethod<void>(
        'load', {'playerId': _playerId, 'path': filePath});
  }

  /// Loads audio from raw bytes already in memory.
  Future<void> loadFromBytes(Uint8List bytes, {String extension = 'wav'}) async {
    _checkNotDisposed();
    await _loadFromBytesWithExtension(bytes, extension);
  }

  /// Loads audio from an HTTP or HTTPS [uri].
  Future<void> loadFromUrl(Uri uri) async {
    _checkNotDisposed();
    await _channel.invokeMethod<void>(
        'loadUrl', {'playerId': _playerId, 'url': uri.toString()});
  }

  Future<void> _loadFromBytesWithExtension(
      Uint8List bytes, String extension) async {
    await getFileUtils().loadFromBytes(_playerId, bytes, extension, loadFromFile);
  }

  /// Starts looping playback from the beginning (or current loop region start).
  Future<void> play() async {
    _checkNotDisposed();
    await _channel.invokeMethod<void>('play', {'playerId': _playerId});
  }

  /// Pauses playback. Call [resume] to continue from the same position.
  Future<void> pause() async {
    _checkNotDisposed();
    await _channel.invokeMethod<void>('pause', {'playerId': _playerId});
  }

  /// Resumes paused playback.
  Future<void> resume() async {
    _checkNotDisposed();
    await _channel.invokeMethod<void>('resume', {'playerId': _playerId});
  }

  /// Stops playback and resets the playback position.
  Future<void> stop() async {
    _checkNotDisposed();
    await _channel.invokeMethod<void>('stop', {'playerId': _playerId});
  }

  /// Sets the loop region in seconds.
  Future<void> setLoopRegion(double start, double end) async {
    _checkNotDisposed();
    if (start < 0) throw ArgumentError.value(start, 'start', 'must be >= 0');
    if (end <= start) throw ArgumentError('end ($end) must be greater than start ($start)');
    await _channel.invokeMethod<void>(
        'setLoopRegion', {'playerId': _playerId, 'start': start, 'end': end});
  }

  /// Sets the crossfade duration in seconds. Pass `0.0` to disable.
  Future<void> setCrossfadeDuration(double seconds) async {
    _checkNotDisposed();
    await _channel.invokeMethod<void>(
        'setCrossfadeDuration', {'playerId': _playerId, 'duration': seconds});
  }

  /// Sets the playback volume. Range: 0.0 (silent) to 1.0 (full volume).
  /// Values outside the range are clamped. Effective volume = localVolume × master.
  Future<void> setVolume(double volume) async {
    _checkNotDisposed();
    _localVolume = volume.clamp(0.0, 1.0);
    await _applyEffectiveVolume();
  }

  /// Sets the stereo pan position in [-1.0, 1.0]. Effective pan = localPan + master.
  Future<void> setPan(double pan) async {
    _checkNotDisposed();
    _localPan = pan.clamp(-1.0, 1.0);
    await _applyEffectivePan();
  }

  Future<void> _applyEffectiveVolume() async {
    final effective =
        (_localVolume * LoopAudioMaster._masterVolume).clamp(0.0, 1.0);
    await _channel.invokeMethod<void>(
        'setVolume', {'playerId': _playerId, 'volume': effective});
  }

  Future<void> _applyEffectivePan() async {
    final effective =
        (_localPan + LoopAudioMaster._masterPan).clamp(-1.0, 1.0);
    await _channel.invokeMethod<void>(
        'setPan', {'playerId': _playerId, 'pan': effective});
  }

  /// Sets the playback rate (speed) multiplier. Range clamped to [0.25, 4.0].
  Future<void> setPlaybackRate(double rate) async {
    _checkNotDisposed();
    await _channel.invokeMethod<void>(
        'setPlaybackRate', {'playerId': _playerId, 'rate': rate.clamp(0.25, 4.0)});
  }

  /// Seeks to [seconds] within the loaded file.
  Future<void> seek(double seconds) async {
    _checkNotDisposed();
    await _channel.invokeMethod<void>(
        'seek', {'playerId': _playerId, 'position': seconds});
  }

  /// Returns the total duration of the loaded file.
  Future<Duration> get duration async {
    _checkNotDisposed();
    final secs = await _channel.invokeMethod<double>(
        'getDuration', {'playerId': _playerId}) ?? 0.0;
    return Duration(milliseconds: (secs * 1000).round());
  }

  /// Returns the current playback position in seconds.
  Future<double> get currentPosition async {
    _checkNotDisposed();
    return await _channel.invokeMethod<double>(
        'getCurrentPosition', {'playerId': _playerId}) ?? 0.0;
  }

  /// Releases all native resources. This instance cannot be used after dispose.
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    _finalizer.detach(this);
    LoopAudioMaster._instances.remove(_weakSelf);
    await _channel.invokeMethod<void>('dispose', {'playerId': _playerId});
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

/// A static group-bus controller for all live [LoopAudioPlayer] instances.
///
/// Volume is multiplicative: `effectiveVolume = localVolume × masterVolume`.
/// Pan is additive (clamped): `effectivePan = clamp(localPan + masterPan, −1.0, 1.0)`.
///
/// ## Example
/// ```dart
/// final p1 = LoopAudioPlayer();
/// final p2 = LoopAudioPlayer();
/// await p1.setVolume(0.8);
/// await p2.setVolume(0.6);
/// await LoopAudioMaster.setVolume(0.5); // p1 → 0.4, p2 → 0.3
/// ```
class LoopAudioMaster {
  LoopAudioMaster._();

  // WeakReference so players can be GC'd (and their Finalizer fired) even when
  // they haven't been explicitly disposed.
  static final Set<WeakReference<LoopAudioPlayer>> _instances = {};
  static double _masterVolume = 1.0;
  static double _masterPan    = 0.0;

  /// Current master volume (0.0–1.0). Default: `1.0`.
  static double get volume => _masterVolume;

  /// Current master pan (−1.0–1.0). Default: `0.0`.
  static double get pan => _masterPan;

  /// Scales all live [LoopAudioPlayer] instances multiplicatively.
  static Future<void> setVolume(double volume) async {
    _masterVolume = volume.clamp(0.0, 1.0);
    await _forEachLive((inst) => inst._applyEffectiveVolume());
  }

  /// Shifts all live [LoopAudioPlayer] pans additively (clamped to ±1.0).
  static Future<void> setPan(double pan) async {
    _masterPan = pan.clamp(-1.0, 1.0);
    await _forEachLive((inst) => inst._applyEffectivePan());
  }

  /// Resets master volume to 1.0 and pan to 0.0, then re-applies to all instances.
  static Future<void> reset() async {
    _masterVolume = 1.0;
    _masterPan    = 0.0;
    await _forEachLive((inst) async {
      await inst._applyEffectiveVolume();
      await inst._applyEffectivePan();
    });
  }

  // Iterates live (non-null, non-disposed) instances; removes stale weak refs.
  static Future<void> _forEachLive(
      Future<void> Function(LoopAudioPlayer) fn) async {
    final stale = <WeakReference<LoopAudioPlayer>>[];
    for (final ref in List.of(_instances)) {
      final inst = ref.target;
      if (inst == null) { stale.add(ref); continue; }
      if (!inst._isDisposed) await fn(inst);
    }
    _instances.removeAll(stale);
  }

  /// Resets master state for use in tests only.
  @visibleForTesting
  static void resetForTesting() {
    _masterVolume = 1.0;
    _masterPan    = 0.0;
    _instances.clear();
  }
}
