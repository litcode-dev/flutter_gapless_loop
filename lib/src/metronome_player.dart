import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A sample-accurate metronome that pre-generates a single-bar PCM buffer and
/// loops it on the native hardware scheduler.
///
/// Runs independently from [LoopAudioPlayer] — both can play simultaneously.
/// Multiple [MetronomePlayer] instances can also run concurrently without
/// cross-talk; each is independently managed by the native layer.
///
/// ## Example
///
/// ```dart
/// final metronome = MetronomePlayer();
/// await metronome.start(
///   bpm: 120.0,
///   beatsPerBar: 4,
///   click: clickBytes,
///   accent: accentBytes,
/// );
/// metronome.beatStream.listen((beat) => print('beat $beat'));
/// // ... later
/// await metronome.stop();
/// await metronome.dispose();
/// ```
///
/// Method channel:  `"flutter_gapless_loop/metronome"`
/// Event channel:   `"flutter_gapless_loop/metronome/events"`
class MetronomePlayer {
  static const _channel =
      MethodChannel('flutter_gapless_loop/metronome');
  static const _eventChannel =
      EventChannel('flutter_gapless_loop/metronome/events');

  static final Stream<Map<Object?, Object?>> _sharedEvents = _eventChannel
      .receiveBroadcastStream()
      .cast<Map<Object?, Object?>>();

  static int _nextId = 0;
  final String _playerId = 'metro_${_nextId++}';

  /// The unique identifier for this metronome instance.
  String get playerId => _playerId;

  late final Stream<Map<Object?, Object?>> _events;
  bool _isDisposed = false;
  double _localVolume = 1.0;
  double _localPan    = 0.0;

  late final WeakReference<MetronomePlayer> _weakSelf;

  // ── Hot-restart guard ──────────────────────────────────────────────────────
  static bool _didClearAll = false;

  // ── GC-based cleanup ───────────────────────────────────────────────────────
  static final Finalizer<String> _finalizer = Finalizer((playerId) {
    _channel.invokeMethod<void>('dispose', {'playerId': playerId});
  });

  MetronomePlayer() {
    _weakSelf = WeakReference(this);
    _events   = _sharedEvents.where((e) => e['playerId'] == _playerId);
    MetronomeMaster._instances.add(_weakSelf);
    _finalizer.attach(this, _playerId, detach: this);

    if (!_didClearAll) {
      _didClearAll = true;
      _channel.invokeMethod<void>('clearAll');
    }
  }

  void _checkNotDisposed() {
    if (_isDisposed) throw StateError('MetronomePlayer has been disposed.');
  }

  /// Starts the metronome.
  ///
  /// [bpm] must be in (0, 400]. [beatsPerBar] must be in [1, 16].
  /// [click] is audio bytes for a regular beat tick.
  /// [accent] is audio bytes for the downbeat (beat 0).
  /// [extension] is the decoder hint (default `'wav'`).
  Future<void> start({
    required double bpm,
    required int beatsPerBar,
    required Uint8List click,
    required Uint8List accent,
    String extension = 'wav',
  }) async {
    _checkNotDisposed();
    if (bpm <= 0 || bpm > 400) {
      throw ArgumentError.value(bpm, 'bpm', 'must be in (0, 400]');
    }
    if (beatsPerBar < 1 || beatsPerBar > 16) {
      throw ArgumentError.value(
          beatsPerBar, 'beatsPerBar', 'must be in [1, 16]');
    }
    await _channel.invokeMethod<void>('start', {
      'playerId': _playerId,
      'bpm': bpm,
      'beatsPerBar': beatsPerBar,
      'click': click,
      'accent': accent,
      'extension': extension,
    });
  }

  /// Stops the metronome immediately.
  Future<void> stop() async {
    _checkNotDisposed();
    await _channel.invokeMethod<void>('stop', {'playerId': _playerId});
  }

  /// Updates tempo without stopping. Regenerates the bar buffer.
  Future<void> setBpm(double bpm) async {
    _checkNotDisposed();
    if (bpm <= 0 || bpm > 400) {
      throw ArgumentError.value(bpm, 'bpm', 'must be in (0, 400]');
    }
    await _channel.invokeMethod<void>('setBpm', {'playerId': _playerId, 'bpm': bpm});
  }

  /// Updates time signature without stopping. Regenerates the bar buffer.
  Future<void> setBeatsPerBar(int beatsPerBar) async {
    _checkNotDisposed();
    if (beatsPerBar < 1 || beatsPerBar > 16) {
      throw ArgumentError.value(
          beatsPerBar, 'beatsPerBar', 'must be in [1, 16]');
    }
    await _channel.invokeMethod<void>(
        'setBeatsPerBar', {'playerId': _playerId, 'beatsPerBar': beatsPerBar});
  }

  /// Beat index emitted on each click: 0 = downbeat, 1…N-1 = regular beats.
  Stream<int> get beatStream {
    _checkNotDisposed();
    return _events
        .where((e) => e['type'] == 'beatTick')
        .map((e) => e['beat'] as int? ?? 0);
  }

  /// Sets this instance's volume (0.0–1.0). Effective = localVolume × master.
  Future<void> setVolume(double volume) async {
    _checkNotDisposed();
    _localVolume = volume.clamp(0.0, 1.0);
    await _applyEffectiveVolume();
  }

  /// Sets this instance's stereo pan (−1.0 to 1.0). Effective = localPan + master.
  Future<void> setPan(double pan) async {
    _checkNotDisposed();
    _localPan = pan.clamp(-1.0, 1.0);
    await _applyEffectivePan();
  }

  Future<void> _applyEffectiveVolume() async {
    final effective =
        (_localVolume * MetronomeMaster._masterVolume).clamp(0.0, 1.0);
    await _channel.invokeMethod<void>(
        'setVolume', {'playerId': _playerId, 'volume': effective});
  }

  Future<void> _applyEffectivePan() async {
    final effective =
        (_localPan + MetronomeMaster._masterPan).clamp(-1.0, 1.0);
    await _channel.invokeMethod<void>(
        'setPan', {'playerId': _playerId, 'pan': effective});
  }

  /// Releases all native resources. This instance cannot be used after dispose.
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    _finalizer.detach(this);
    MetronomeMaster._instances.remove(_weakSelf);
    await _channel.invokeMethod<void>('dispose', {'playerId': _playerId});
  }
}

/// A static group-bus controller for all live [MetronomePlayer] instances.
///
/// Volume is multiplicative: `effectiveVolume = localVolume × masterVolume`.
/// Pan is additive (clamped): `effectivePan = clamp(localPan + masterPan, −1.0, 1.0)`.
///
/// ## Example
/// ```dart
/// final m1 = MetronomePlayer();
/// final m2 = MetronomePlayer();
/// await m1.setVolume(0.8);
/// await m2.setVolume(0.6);
/// await MetronomeMaster.setVolume(0.5); // m1 → 0.4, m2 → 0.3
/// ```
class MetronomeMaster {
  MetronomeMaster._();

  static final Set<WeakReference<MetronomePlayer>> _instances = {};
  static double _masterVolume = 1.0;
  static double _masterPan    = 0.0;

  /// Current master volume (0.0–1.0). Default: `1.0`.
  static double get volume => _masterVolume;

  /// Current master pan (−1.0–1.0). Default: `0.0`.
  static double get pan => _masterPan;

  /// Scales all live [MetronomePlayer] instances multiplicatively.
  static Future<void> setVolume(double volume) async {
    _masterVolume = volume.clamp(0.0, 1.0);
    await _forEachLive((inst) => inst._applyEffectiveVolume());
  }

  /// Shifts all live [MetronomePlayer] pans additively (clamped to ±1.0).
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

  static Future<void> _forEachLive(
      Future<void> Function(MetronomePlayer) fn) async {
    final stale = <WeakReference<MetronomePlayer>>[];
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
