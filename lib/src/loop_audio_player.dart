import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'loop_audio_state.dart';
import 'metronome_player.dart';
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

  // ── A-B loop points ────────────────────────────────────────────────────────
  double? _loopPointA;
  double? _loopPointB;

  // ── Effects state (for captureEffectsPreset) ───────────────────────────────
  EqSettings _currentEq = const EqSettings();
  ReverbPreset _currentReverbPreset = ReverbPreset.smallRoom;
  double _currentReverbWetMix = 0.0;
  CompressorSettings _currentCompressor = const CompressorSettings();

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

  // ── Core streams ──────────────────────────────────────────────────────────

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

  // ── Tier 1: seekCompleteStream ────────────────────────────────────────────

  /// Fires with the final position (in seconds) each time a seek operation
  /// completes on the native layer.
  Stream<double> get seekCompleteStream {
    _checkNotDisposed();
    return _events
        .where((e) => e['type'] == 'seekComplete')
        .map((e) => (e['position'] as num? ?? 0).toDouble());
  }

  // ── Tier 1: remoteCommandStream ───────────────────────────────────────────

  /// Stream of commands from the lock screen, headphones, CarPlay, or
  /// Android notification buttons.
  ///
  /// Call [enableRemoteCommands] to start receiving events.
  Stream<RemoteCommandEvent> get remoteCommandStream {
    _checkNotDisposed();
    return _events
        .where((e) => e['type'] == 'remoteCommand')
        .map((e) {
          final cmd = _parseRemoteCommand(e['command'] as String? ?? '');
          final pos = (e['position'] as num?)?.toDouble();
          return RemoteCommandEvent(cmd, position: pos);
        });
  }

  RemoteCommand _parseRemoteCommand(String s) => switch (s) {
    'play'                   => RemoteCommand.play,
    'pause'                  => RemoteCommand.pause,
    'stop'                   => RemoteCommand.stop,
    'nextTrack'              => RemoteCommand.nextTrack,
    'previousTrack'          => RemoteCommand.previousTrack,
    'seekForward'            => RemoteCommand.seekForward,
    'seekBackward'           => RemoteCommand.seekBackward,
    'changePlaybackPosition' => RemoteCommand.changePlaybackPosition,
    'togglePlayPause'        => RemoteCommand.togglePlayPause,
    _                        => RemoteCommand.togglePlayPause,
  };

  // ── Tier 1: interruptionStream ────────────────────────────────────────────

  /// Stream of audio interruption events (phone call, Siri, audio focus loss).
  ///
  /// On iOS the engine automatically pauses on [InterruptionType.began].
  /// On Android the engine pauses on audio focus loss.
  Stream<InterruptionEvent> get interruptionStream {
    _checkNotDisposed();
    return _events
        .where((e) => e['type'] == 'interruption')
        .map((e) {
          final t = (e['interruptionType'] as String?) == 'began'
              ? InterruptionType.began
              : InterruptionType.ended;
          return InterruptionEvent(t, shouldResume: e['shouldResume'] as bool? ?? false);
        });
  }

  // ── Tier 3: spectrumStream ────────────────────────────────────────────────

  /// Real-time FFT spectrum data. Enable with [enableSpectrum].
  Stream<SpectrumData> get spectrumStream {
    _checkNotDisposed();
    return _events
        .where((e) => e['type'] == 'spectrum')
        .map((e) => SpectrumData.fromList(e['magnitudes'] as List<Object?>? ?? []));
  }

  // ── Load methods ──────────────────────────────────────────────────────────

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

  // ── Playback controls ─────────────────────────────────────────────────────

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

  // ── Tier 1: setPitch ──────────────────────────────────────────────────────

  /// Sets the pitch offset in semitones, independent of playback rate.
  /// Range: ±24 semitones (clamped).
  Future<void> setPitch(double semitones) async {
    _checkNotDisposed();
    await _channel.invokeMethod<void>(
        'setPitch', {'playerId': _playerId, 'semitones': semitones.clamp(-24.0, 24.0)});
  }

  // ── Tier 1: NowPlayingInfo ────────────────────────────────────────────────

  /// Updates the iOS MPNowPlayingInfoCenter and Android media notification.
  Future<void> setNowPlayingInfo(NowPlayingInfo info) async {
    _checkNotDisposed();
    await _channel.invokeMethod<void>('setNowPlayingInfo', {
      'playerId': _playerId,
      if (info.title    != null) 'title':    info.title,
      if (info.artist   != null) 'artist':   info.artist,
      if (info.album    != null) 'album':    info.album,
      if (info.artworkBytes != null) 'artworkBytes': info.artworkBytes,
      'artworkMimeType': info.artworkMimeType,
      if (info.duration != null) 'duration': info.duration,
      if (info.elapsed  != null) 'elapsed':  info.elapsed,
    });
  }

  /// Clears the iOS MPNowPlayingInfoCenter and Android media notification.
  Future<void> clearNowPlayingInfo() async {
    _checkNotDisposed();
    await _channel.invokeMethod<void>('clearNowPlayingInfo', {'playerId': _playerId});
  }

  // ── Tier 1: RemoteCommands ────────────────────────────────────────────────

  /// Registers for lock-screen / headphones / CarPlay / Android notification
  /// remote commands. Events arrive via [remoteCommandStream].
  Future<void> enableRemoteCommands() async {
    _checkNotDisposed();
    await _channel.invokeMethod<void>('enableRemoteCommands', {'playerId': _playerId});
  }

  /// Unregisters all remote command handlers.
  Future<void> disableRemoteCommands() async {
    _checkNotDisposed();
    await _channel.invokeMethod<void>('disableRemoteCommands', {'playerId': _playerId});
  }

  // ── Tier 2: Beat-synced seek ──────────────────────────────────────────────

  /// Seeks to the nearest beat position at or before [currentPos].
  Future<void> seekToNearestBeat(BpmResult bpm, double currentPos) async {
    final beats = bpm.beats;
    if (beats.isEmpty) { await seek(currentPos); return; }
    double nearest = beats.first;
    for (final b in beats) {
      if (b <= currentPos) nearest = b;
    }
    await seek(nearest);
  }

  /// Seeks to the beat at [beatIndex] (0-based) in [bpm.beats].
  Future<void> seekToBeat(BpmResult bpm, int beatIndex) async {
    final beats = bpm.beats;
    if (beatIndex < 0 || beatIndex >= beats.length) {
      throw RangeError.range(beatIndex, 0, beats.length - 1, 'beatIndex');
    }
    await seek(beats[beatIndex]);
  }

  /// Seeks to the bar at [barIndex] (0-based) in [bpm.bars].
  Future<void> seekToBar(BpmResult bpm, int barIndex) async {
    final bars = bpm.bars;
    if (barIndex < 0 || barIndex >= bars.length) {
      throw RangeError.range(barIndex, 0, bars.length - 1, 'barIndex');
    }
    await seek(bars[barIndex]);
  }

  // ── Tier 2: Count-in ──────────────────────────────────────────────────────

  /// Waits [bars] bars of the metronome then starts playback.
  ///
  /// The [metro] must already be running. Playback starts after the specified
  /// number of bars have elapsed as counted by [metro.beatStream].
  Future<void> playAfterCountIn(
    MetronomePlayer metro,
    BpmResult bpm, {
    int bars = 1,
  }) async {
    _checkNotDisposed();
    if (bars <= 0) throw ArgumentError.value(bars, 'bars', 'must be >= 1');
    int remaining = bars * (bpm.beatsPerBar > 0 ? bpm.beatsPerBar : 4);
    final completer = Completer<void>();
    late StreamSubscription<int> sub;
    sub = metro.beatStream.listen((beat) {
      remaining--;
      if (remaining <= 0) {
        sub.cancel();
        if (!completer.isCompleted) completer.complete();
      }
    });
    await completer.future;
    await play();
  }

  // ── Tier 2: Fades ─────────────────────────────────────────────────────────

  /// Fades volume to [targetVolume] over [duration] using native 100 Hz ramp.
  Future<void> fadeTo(double targetVolume, Duration duration) async {
    _checkNotDisposed();
    await _channel.invokeMethod<void>('fadeTo', {
      'playerId':    _playerId,
      'targetVolume': targetVolume.clamp(0.0, 1.0),
      'durationMs':   duration.inMilliseconds,
    });
  }

  /// Fades volume from current level to 1.0.
  Future<void> fadeIn(Duration duration) => fadeTo(1.0, duration);

  /// Fades volume from current level to 0.0.
  Future<void> fadeOut(Duration duration) => fadeTo(0.0, duration);

  // ── Tier 2: Waveform data ─────────────────────────────────────────────────

  /// Returns a downsampled peak array for waveform display.
  ///
  /// [numSamples] is the number of output data points (default 1024).
  /// Each value is a normalised peak in [0.0, 1.0].
  Future<Float32List> getWaveformData({int numSamples = 1024}) async {
    _checkNotDisposed();
    final List<Object?>? raw = await _channel.invokeMethod<List<Object?>>(
        'getWaveformData', {'playerId': _playerId, 'numSamples': numSamples});
    if (raw == null) return Float32List(0);
    final result = Float32List(raw.length);
    for (int i = 0; i < raw.length; i++) {
      result[i] = (raw[i] as num).toDouble().clamp(0.0, 1.0);
    }
    return result;
  }

  // ── Tier 2: Silence detection ─────────────────────────────────────────────

  /// Detects contiguous silent regions in the loaded file.
  ///
  /// [threshold] is the amplitude below which a sample is considered silent
  /// (default 0.01). [minDuration] is the minimum length in seconds for a
  /// region to be reported (default 0.1 s).
  Future<List<SilenceRegion>> detectSilence({
    double threshold  = 0.01,
    double minDuration = 0.1,
  }) async {
    _checkNotDisposed();
    final raw = await _channel.invokeMethod<List<Object?>>(
      'detectSilence',
      {'playerId': _playerId, 'threshold': threshold, 'minDuration': minDuration},
    );
    if (raw == null) return [];
    return raw
        .whereType<Map<Object?, Object?>>()
        .map(SilenceRegion.fromMap)
        .toList();
  }

  /// Detects leading/trailing silence and applies those boundaries as the loop
  /// region, effectively trimming silence from playback.
  Future<void> trimSilence({
    double threshold   = 0.01,
    double minDuration = 0.05,
  }) async {
    _checkNotDisposed();
    await _channel.invokeMethod<void>(
      'trimSilence',
      {'playerId': _playerId, 'threshold': threshold, 'minDuration': minDuration},
    );
  }

  // ── Tier 2: LUFS loudness ─────────────────────────────────────────────────

  /// Returns the integrated loudness of the loaded file in LUFS (EBU R128).
  ///
  /// Returns a negative value, e.g. −14.0 LUFS. Returns −70.0 if unavailable.
  Future<double> getLoudness() async {
    _checkNotDisposed();
    return await _channel.invokeMethod<double>(
        'getLoudness', {'playerId': _playerId}) ?? -70.0;
  }

  /// Adjusts volume to reach [targetLufs] based on measured integrated loudness.
  Future<void> normaliseLoudness({double targetLufs = -14.0}) async {
    _checkNotDisposed();
    await _channel.invokeMethod<void>(
      'normaliseLoudness',
      {'playerId': _playerId, 'targetLufs': targetLufs},
    );
  }

  // ── Tier 3: 3-band EQ ─────────────────────────────────────────────────────

  /// Applies 3-band EQ settings (80 Hz low shelf, 1 kHz peak, 10 kHz high shelf).
  Future<void> setEq(EqSettings settings) async {
    _checkNotDisposed();
    _currentEq = settings;
    await _channel.invokeMethod<void>('setEq', {
      'playerId': _playerId,
      ...settings.toMap(),
    });
  }

  /// Resets all EQ bands to 0 dB (bypassed).
  Future<void> resetEq() async {
    _checkNotDisposed();
    _currentEq = const EqSettings();
    await _channel.invokeMethod<void>('resetEq', {'playerId': _playerId});
  }

  // ── Tier 3: Reverb ────────────────────────────────────────────────────────

  /// Applies reverb with the given [preset] and wet/dry [wetMix] (0.0–1.0).
  Future<void> setReverb(ReverbPreset preset, {double wetMix = 0.3}) async {
    _checkNotDisposed();
    _currentReverbPreset = preset;
    _currentReverbWetMix = wetMix;
    await _channel.invokeMethod<void>('setReverb', {
      'playerId': _playerId,
      'preset':   preset.index,
      'wetMix':   wetMix.clamp(0.0, 1.0),
    });
  }

  /// Disables reverb (bypasses the reverb node).
  Future<void> disableReverb() async {
    _checkNotDisposed();
    await _channel.invokeMethod<void>('disableReverb', {'playerId': _playerId});
  }

  // ── Tier 3: Compressor ────────────────────────────────────────────────────

  /// Applies dynamic-range compression with the given [settings].
  Future<void> setCompressor(CompressorSettings settings) async {
    _checkNotDisposed();
    _currentCompressor = settings;
    await _channel.invokeMethod<void>('setCompressor', {
      'playerId': _playerId,
      ...settings.toMap(),
    });
  }

  /// Disables the compressor (bypasses the compressor node).
  Future<void> disableCompressor() async {
    _checkNotDisposed();
    await _channel.invokeMethod<void>('disableCompressor', {'playerId': _playerId});
  }

  // ── Tier 3: FFT spectrum ──────────────────────────────────────────────────

  /// Starts emitting real-time FFT data on [spectrumStream].
  Future<void> enableSpectrum() async {
    _checkNotDisposed();
    await _channel.invokeMethod<void>('enableSpectrum', {'playerId': _playerId});
  }

  /// Stops FFT spectrum emission.
  Future<void> disableSpectrum() async {
    _checkNotDisposed();
    await _channel.invokeMethod<void>('disableSpectrum', {'playerId': _playerId});
  }

  // ── Tier 3: WAV export ────────────────────────────────────────────────────

  /// Exports the loaded audio (or a region of it) to a WAV file.
  ///
  /// [outputPath] must be a writable absolute file path.
  /// [format] selects 32-bit float or 16-bit integer PCM.
  /// [regionStart] / [regionEnd] optionally restrict the exported region.
  Future<void> exportToFile(
    String outputPath, {
    ExportFormat format  = ExportFormat.wav32bit,
    double? regionStart,
    double? regionEnd,
  }) async {
    _checkNotDisposed();
    await _channel.invokeMethod<void>('exportToFile', {
      'playerId':   _playerId,
      'outputPath': outputPath,
      'format':     format.index,
      if (regionStart != null) 'regionStart': regionStart,
      if (regionEnd   != null) 'regionEnd':   regionEnd,
    });
  }

  // ── Tier 3: A-B loop points ───────────────────────────────────────────────

  /// The current A and B loop points (may be null if not yet set).
  LoopPoints get loopPoints => LoopPoints(pointA: _loopPointA, pointB: _loopPointB);

  /// Saves the current playback position as loop point A.
  Future<void> saveLoopPointA() async {
    _checkNotDisposed();
    _loopPointA = await currentPosition;
  }

  /// Saves the current playback position as loop point B.
  Future<void> saveLoopPointB() async {
    _checkNotDisposed();
    _loopPointB = await currentPosition;
  }

  /// Applies the saved A-B loop points as the active loop region.
  ///
  /// Throws [StateError] if both points are not yet set.
  Future<void> recallABLoop() async {
    _checkNotDisposed();
    final a = _loopPointA, b = _loopPointB;
    if (a == null || b == null) {
      throw StateError('Both loop points A and B must be set first');
    }
    await setLoopRegion(a < b ? a : b, a < b ? b : a);
  }

  /// Clears both A and B loop points.
  void clearLoopPoints() {
    _loopPointA = null;
    _loopPointB = null;
  }

  // ── Tier 3: Effects preset ────────────────────────────────────────────────

  /// Captures a snapshot of the current DSP effect settings.
  Future<EffectsPreset> captureEffectsPreset() async {
    _checkNotDisposed();
    return EffectsPreset(
      eq:           _currentEq,
      reverb:       _currentReverbPreset,
      reverbWetMix: _currentReverbWetMix,
      compressor:   _currentCompressor,
    );
  }

  /// Applies all settings from [preset] atomically.
  Future<void> applyEffectsPreset(EffectsPreset preset) async {
    _checkNotDisposed();
    _currentEq             = preset.eq;
    _currentReverbPreset   = preset.reverb;
    _currentReverbWetMix   = preset.reverbWetMix;
    _currentCompressor     = preset.compressor;
    await setEq(preset.eq);
    await setReverb(preset.reverb, wetMix: preset.reverbWetMix);
    await setCompressor(preset.compressor);
  }

  // ── Dispose ───────────────────────────────────────────────────────────────

  /// Releases all native resources. This instance cannot be used after dispose.
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    _finalizer.detach(this);
    LoopAudioMaster._instances.remove(_weakSelf);
    await _channel.invokeMethod<void>('dispose', {'playerId': _playerId});
  }

  // ── Private helpers ───────────────────────────────────────────────────────

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
