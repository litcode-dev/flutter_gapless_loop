import 'dart:async';
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

  // Shared broadcast stream — one subscription for all instances, each filters
  // by its own playerId so beat ticks don't cross-talk.
  static final Stream<Map<Object?, Object?>> _sharedEvents = _eventChannel
      .receiveBroadcastStream()
      .cast<Map<Object?, Object?>>();

  static int _nextId = 0;
  final String _playerId = 'metro_${_nextId++}';

  /// The unique identifier for this metronome instance.
  String get playerId => _playerId;

  late final Stream<Map<Object?, Object?>> _events;
  bool _isDisposed = false;

  MetronomePlayer() {
    _events = _sharedEvents.where((e) => e['playerId'] == _playerId);
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
  ///
  /// [bpm] must be in (0, 400].
  Future<void> setBpm(double bpm) async {
    _checkNotDisposed();
    if (bpm <= 0 || bpm > 400) {
      throw ArgumentError.value(bpm, 'bpm', 'must be in (0, 400]');
    }
    await _channel.invokeMethod<void>('setBpm', {'playerId': _playerId, 'bpm': bpm});
  }

  /// Updates time signature without stopping. Regenerates the bar buffer.
  ///
  /// [beatsPerBar] must be in [1, 16].
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
  ///
  /// UI hint only — not used for audio scheduling (±5 ms jitter acceptable).
  Stream<int> get beatStream {
    _checkNotDisposed();
    return _events
        .where((e) => e['type'] == 'beatTick')
        .map((e) => e['beat'] as int? ?? 0);
  }

  /// Releases all native resources. This instance cannot be used after dispose.
  Future<void> dispose() async {
    _isDisposed = true;
    await _channel.invokeMethod<void>('dispose', {'playerId': _playerId});
  }
}
