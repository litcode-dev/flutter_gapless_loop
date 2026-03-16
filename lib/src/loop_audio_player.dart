import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'loop_audio_state.dart';
import 'metronome_player.dart';

/// A player for sample-accurate gapless audio looping on iOS and Android.
///
/// Uses [MethodChannel] for commands and [EventChannel] for state/error/route events.
///
/// All methods and getters may throw [PlatformException] if the native engine
/// returns an error.
///
/// Multiple [LoopAudioPlayer] instances can run concurrently without cross-talk —
/// each instance is independently managed by the native layer.
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

  /// Creates a new [LoopAudioPlayer].
  LoopAudioPlayer() {
    _events = _sharedEvents.where((e) => e['playerId'] == _playerId);
    LoopAudioMaster._instances.add(this);
  }

  void _checkNotDisposed() {
    if (_isDisposed) throw StateError('LoopAudioPlayer has been disposed.');
  }

  // ── Streams ──────────────────────────────────────────────────────────────

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

  /// Stream of [InterruptionEvent]s pushed when the system interrupts or
  /// resumes audio (phone calls, Siri, other apps requesting audio focus).
  ///
  /// The player automatically pauses on [InterruptionType.began] — listen to
  /// this stream if you need to update your UI accordingly.
  Stream<InterruptionEvent> get interruptionStream {
    _checkNotDisposed();
    return _events
        .where((e) => e['type'] == 'interruption')
        .map((e) => InterruptionEvent(
              e['interruptionType'] == 'began'
                  ? InterruptionType.began
                  : InterruptionType.ended,
            ));
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

  /// Stream that emits the seek position (in seconds) once the native engine
  /// has rescheduled its buffers after a [seek] call.
  ///
  /// Useful for confirming the seek completed before updating UI or
  /// synchronising with other players.
  Stream<double> get seekCompleteStream {
    _checkNotDisposed();
    return _events
        .where((e) => e['type'] == 'seekComplete')
        .map((e) => (e['position'] as num? ?? 0).toDouble());
  }

  /// Stream of [RemoteCommand]s from the system lock screen, headphone
  /// buttons, CarPlay, or Android media notification.
  ///
  /// The app must act on these commands — the plugin does NOT automatically
  /// call [play] or [pause] in response:
  ///
  /// ```dart
  /// player.remoteCommandStream.listen((cmd) async {
  ///   if (cmd is RemotePlayCommand)  await player.play();
  ///   if (cmd is RemotePauseCommand) await player.pause();
  ///   if (cmd is RemoteSeekCommand)  await player.seek(cmd.position);
  /// });
  /// ```
  ///
  /// Commands are only emitted while [setNowPlayingInfo] has been called at
  /// least once for this player.
  Stream<RemoteCommand> get remoteCommandStream {
    _checkNotDisposed();
    return _events
        .where((e) => e['type'] == 'remoteCommand')
        .map(_parseRemoteCommand)
        .whereType<RemoteCommand>();
  }

  // ── Loading ───────────────────────────────────────────────────────────────

  /// Loads an audio file from a Flutter asset key (e.g. `'assets/loop.wav'`).
  /// The native layer resolves the asset key to an absolute path using the
  /// Flutter asset registry.
  ///
  /// Throws [PlatformException] on native error.
  Future<void> load(String assetPath) async {
    _checkNotDisposed();
    await _channel.invokeMethod<void>(
        'loadAsset', {'playerId': _playerId, 'assetKey': assetPath});
  }

  /// Loads an audio file from an absolute file system path.
  ///
  /// Throws [PlatformException] on native error.
  Future<void> loadFromFile(String filePath) async {
    _checkNotDisposed();
    await _channel.invokeMethod<void>(
        'load', {'playerId': _playerId, 'path': filePath});
  }

  /// Loads audio from raw bytes already in memory (e.g. from `dart:io`, a
  /// network response body, or generated audio data).
  ///
  /// The bytes are written to a temporary file with the given [extension] hint
  /// (default `'wav'`), loaded via the native engine, then the temporary file
  /// is deleted.
  ///
  /// Throws [PlatformException] on native decode or engine error.
  Future<void> loadFromBytes(Uint8List bytes, {String extension = 'wav'}) async {
    _checkNotDisposed();
    await _loadFromBytesWithExtension(bytes, extension);
  }

  /// Loads audio from an HTTP or HTTPS [uri].
  ///
  /// The download is performed natively (URLSession on iOS,
  /// HttpURLConnection on Android) — no Dart HTTP client is used.
  /// The temporary file is deleted by the native layer after load.
  ///
  /// Throws [PlatformException] on download failure (non-2xx) or decode error.
  Future<void> loadFromUrl(Uri uri) async {
    _checkNotDisposed();
    await _channel.invokeMethod<void>(
        'loadUrl', {'playerId': _playerId, 'url': uri.toString()});
  }

  /// Writes [bytes] to a temp file with the given [extension], calls
  /// [loadFromFile], then deletes the temp file unconditionally.
  Future<void> _loadFromBytesWithExtension(
      Uint8List bytes, String extension) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final tmp = File(
        '${Directory.systemTemp.path}/flutter_gapless_$timestamp.$extension');
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      await loadFromFile(tmp.path);
    } finally {
      if (await tmp.exists()) await tmp.delete();
    }
  }

  // ── Transport ──────────────────────────────────────────────────────────────

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

  // ── Loop region / crossfade ───────────────────────────────────────────────

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
    await _channel.invokeMethod<void>(
        'setLoopRegion', {'playerId': _playerId, 'start': start, 'end': end});
  }

  /// Sets the crossfade duration in seconds.
  ///
  /// A value of `0.0` (the default) disables crossfade and uses the lowest-latency
  /// `.loops` scheduling path (Mode A or B). Values greater than `0.0` activate
  /// the dual-node crossfade system (Mode C or D).
  Future<void> setCrossfadeDuration(double seconds) async {
    _checkNotDisposed();
    await _channel.invokeMethod<void>(
        'setCrossfadeDuration', {'playerId': _playerId, 'duration': seconds});
  }

  // ── Audio controls ────────────────────────────────────────────────────────

  /// Sets the playback volume. Range: 0.0 (silent) to 1.0 (full volume).
  ///
  /// Values outside the range are clamped. The effective volume sent to native
  /// is `localVolume × LoopAudioMaster.volume`.
  Future<void> setVolume(double volume) async {
    _checkNotDisposed();
    _localVolume = volume.clamp(0.0, 1.0);
    await _applyEffectiveVolume();
  }

  /// Sets the stereo pan position.
  ///
  /// [pan] is in [-1.0, 1.0]:
  /// - `-1.0` = full left
  /// - `0.0`  = centre (default)
  /// - `1.0`  = full right
  ///
  /// Values outside the range are clamped. The effective pan sent to native
  /// is `clamp(localPan + LoopAudioMaster.pan, −1.0, 1.0)`.
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

  /// Sets the playback rate (speed) while preserving pitch.
  ///
  /// [rate] is a multiplier relative to the original tempo:
  /// - `1.0` = normal speed (default)
  /// - `2.0` = double speed
  /// - `0.5` = half speed
  ///
  /// Values outside [0.25, 4.0] are clamped.
  /// Takes effect immediately. Persists across loads.
  ///
  /// Throws [PlatformException] on native error.
  Future<void> setPlaybackRate(double rate) async {
    _checkNotDisposed();
    await _channel.invokeMethod<void>(
        'setPlaybackRate', {'playerId': _playerId, 'rate': rate.clamp(0.25, 4.0)});
  }

  /// Shifts the pitch by [semitones] without changing playback speed.
  ///
  /// `0.0` = no shift (default). Positive values raise pitch; negative lower it.
  /// Values outside [−24.0, 24.0] (±2 octaves) are clamped.
  ///
  /// This is independent of [setPlaybackRate]: you can time-stretch and
  /// pitch-shift simultaneously with different values.
  ///
  /// On iOS this uses `AVAudioUnitTimePitch.pitch` (pitch property in cents).
  /// On Android this uses `PlaybackParams.setPitch()`.
  ///
  /// Throws [PlatformException] on native error.
  Future<void> setPitch(double semitones) async {
    _checkNotDisposed();
    await _channel.invokeMethod<void>(
        'setPitch', {'playerId': _playerId, 'semitones': semitones.clamp(-24.0, 24.0)});
  }

  // ── Seek ──────────────────────────────────────────────────────────────────

  /// Seeks to [seconds] within the loaded file.
  ///
  /// Listen to [seekCompleteStream] if you need confirmation that the native
  /// engine has rescheduled its buffers.
  ///
  /// Throws [PlatformException] on native error.
  Future<void> seek(double seconds) async {
    _checkNotDisposed();
    await _channel.invokeMethod<void>(
        'seek', {'playerId': _playerId, 'position': seconds});
  }

  /// Seeks to the beat in [bpmResult] nearest to [position] seconds.
  ///
  /// Pure-Dart: no native round-trip. Equivalent to calling [seek] with the
  /// closest beat timestamp from [BpmResult.beats].
  ///
  /// Does nothing if [bpmResult.beats] is empty.
  Future<void> seekToNearestBeat(double position, BpmResult bpmResult) async {
    if (bpmResult.beats.isEmpty) return;
    final beats = bpmResult.beats;
    double nearest = beats[0];
    double minDiff = (position - beats[0]).abs();
    for (final b in beats) {
      final diff = (position - b).abs();
      if (diff < minDiff) { minDiff = diff; nearest = b; }
    }
    await seek(nearest);
  }

  /// Seeks to beat number [beatIndex] (zero-based) in [bpmResult].
  ///
  /// Clamps [beatIndex] to the valid range. Does nothing if [bpmResult.beats]
  /// is empty.
  Future<void> seekToBeat(int beatIndex, BpmResult bpmResult) async {
    if (bpmResult.beats.isEmpty) return;
    final idx = beatIndex.clamp(0, bpmResult.beats.length - 1);
    await seek(bpmResult.beats[idx]);
  }

  /// Seeks to bar number [barIndex] (zero-based) in [bpmResult].
  ///
  /// Clamps [barIndex] to the valid range. Does nothing if [bpmResult.bars]
  /// is empty.
  Future<void> seekToBar(int barIndex, BpmResult bpmResult) async {
    if (bpmResult.bars.isEmpty) return;
    final idx = barIndex.clamp(0, bpmResult.bars.length - 1);
    await seek(bpmResult.bars[idx]);
  }

  // ── Fades ─────────────────────────────────────────────────────────────────

  /// Ramps the output volume from the current value to [targetVolume] over
  /// [duration].
  ///
  /// [targetVolume] is clamped to `[0.0, 1.0]`. [duration] must be positive.
  /// The ramp is handled entirely in the native audio thread for click-free
  /// fades even at short durations.
  ///
  /// This method updates the player's local volume so that subsequent calls to
  /// [LoopAudioMaster.setVolume] compute the effective volume correctly.
  Future<void> fadeTo(double targetVolume,
      {Duration duration = const Duration(milliseconds: 500)}) async {
    _checkNotDisposed();
    _localVolume = targetVolume.clamp(0.0, 1.0);
    final targetEffective =
        (_localVolume * LoopAudioMaster._masterVolume).clamp(0.0, 1.0);
    await _channel.invokeMethod<void>('fadeTo', {
      'playerId':       _playerId,
      'targetVolume':   targetEffective,
      'durationMillis': duration.inMilliseconds,
    });
  }

  /// Fades volume from `0.0` to the current local volume over [duration].
  ///
  /// Useful for a smooth start when [play] or [resume] is called.
  Future<void> fadeIn({Duration duration = const Duration(milliseconds: 500)}) async {
    _checkNotDisposed();
    final targetEffective =
        (_localVolume * LoopAudioMaster._masterVolume).clamp(0.0, 1.0);
    await _channel.invokeMethod<void>('fadeTo', {
      'playerId':         _playerId,
      'targetVolume':     targetEffective,
      'durationMillis':   duration.inMilliseconds,
      'startFromSilence': true,
    });
  }

  /// Fades volume from the current level to `0.0` over [duration].
  Future<void> fadeOut({Duration duration = const Duration(milliseconds: 500)}) async {
    _checkNotDisposed();
    await _channel.invokeMethod<void>('fadeTo', {
      'playerId':       _playerId,
      'targetVolume':   0.0,
      'durationMillis': duration.inMilliseconds,
    });
  }

  // ── Analysis ───────────────────────────────────────────────────────────────

  /// Returns a [WaveformData] with [resolution] data points.
  ///
  /// Each point is the peak absolute amplitude within its segment in `[0.0, 1.0]`.
  /// Suitable for drawing a waveform overview. Computation is performed natively
  /// on a background thread.
  ///
  /// [resolution] is clamped to `[2, 8192]`.
  Future<WaveformData> getWaveformData({int resolution = 400}) async {
    _checkNotDisposed();
    final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'getWaveformData', {
      'playerId':   _playerId,
      'resolution': resolution.clamp(2, 8192),
    });
    return WaveformData.fromMap(raw ?? {});
  }

  /// Scans the loaded audio for silence below [thresholdDb] and returns a
  /// [SilenceInfo] describing the non-silent region.
  ///
  /// [thresholdDb] is the dBFS threshold (negative value, e.g. `-60.0`).
  /// Samples below this level are considered silent.
  ///
  /// Computation is native and runs on a background thread.
  Future<SilenceInfo> detectSilence({double thresholdDb = -60.0}) async {
    _checkNotDisposed();
    final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'detectSilence', {
      'playerId':    _playerId,
      'thresholdDb': thresholdDb,
    });
    return SilenceInfo.fromMap(raw ?? {});
  }

  /// Detects leading/trailing silence and applies the non-silent region as the
  /// loop region via [setLoopRegion].
  ///
  /// Equivalent to calling [detectSilence] then [setLoopRegion] with the result.
  Future<void> trimSilence({double thresholdDb = -60.0}) async {
    final info = await detectSilence(thresholdDb: thresholdDb);
    if (info.duration > 0) {
      await setLoopRegion(info.start, info.end);
    }
  }

  /// Measures the integrated loudness of the loaded audio using the
  /// EBU R128 / ITU-R BS.1770-4 K-weighting algorithm.
  ///
  /// Returns a [LoudnessInfo] with the result in LUFS. Computation is native
  /// and runs synchronously on the calling coroutine/thread.
  Future<LoudnessInfo> getLoudness() async {
    _checkNotDisposed();
    final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'getLoudness', {'playerId': _playerId});
    return LoudnessInfo.fromMap(raw ?? {});
  }

  /// Normalises playback volume so the perceived loudness matches
  /// [targetLufs] (default `-14.0` LUFS, a common streaming target).
  ///
  /// Calls [getLoudness], computes the gain delta, and applies it via
  /// [setVolume]. This is a non-destructive gain adjustment — the underlying
  /// audio is not modified.
  ///
  /// Returns immediately without changing volume if the audio is silent
  /// (LUFS ≤ -70.0).
  Future<void> normaliseLoudness({double targetLufs = -14.0}) async {
    final info = await getLoudness();
    if (info.lufs <= -70.0) return; // silence — skip
    final gainDb    = targetLufs - info.lufs;
    final gainLinear = _dbToLinear(gainDb);
    await setVolume((_localVolume * gainLinear).clamp(0.0, 1.0));
  }

  // ── Position / duration ───────────────────────────────────────────────────

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

  // ── Now Playing / lock screen ─────────────────────────────────────────────

  /// Populates the system media UI (iOS lock screen / Control Center,
  /// Android media notification) with the given [info].
  ///
  /// This also enables [remoteCommandStream]: once called, the system will
  /// deliver lock-screen / headphone button commands to the app.
  ///
  /// Call this whenever the loaded file changes, or when playback begins.
  ///
  /// On Android, calling this method starts a foreground service so audio
  /// continues to play when the screen is off. The service stops automatically
  /// when [stop] or [dispose] is called.
  ///
  /// **iOS setup required:** add `audio` to `UIBackgroundModes` in your app's
  /// `Info.plist` for background audio to work:
  /// ```xml
  /// <key>UIBackgroundModes</key>
  /// <array><string>audio</string></array>
  /// ```
  Future<void> setNowPlayingInfo(NowPlayingInfo info) async {
    _checkNotDisposed();
    await _channel.invokeMethod<void>('setNowPlayingInfo', {
      'playerId': _playerId,
      if (info.title != null)        'title':        info.title,
      if (info.artist != null)       'artist':       info.artist,
      if (info.album != null)        'album':        info.album,
      if (info.duration != null)     'duration':     info.duration,
      if (info.artworkBytes != null) 'artworkBytes': info.artworkBytes,
    });
  }

  /// Clears the system media UI and removes the lock-screen / notification
  /// entry set by [setNowPlayingInfo].
  Future<void> clearNowPlayingInfo() async {
    _checkNotDisposed();
    await _channel.invokeMethod<void>('clearNowPlayingInfo', {'playerId': _playerId});
  }

  // ── EQ / Reverb / Compressor ─────────────────────────────────────────────

  /// Applies a 3-band equaliser.
  ///
  /// [bass] controls an 80 Hz low-shelf, [mid] a 1 kHz parametric peak, and
  /// [treble] a 10 kHz high-shelf. All gains are in dB and clamped to ±12 dB.
  ///
  /// Call `setEq(EqSettings.flat)` or [resetEq] to return to neutral.
  Future<void> setEq(EqSettings settings) async {
    _checkNotDisposed();
    _currentEq = settings;
    await _channel.invokeMethod<void>('setEq', {
      'playerId': _playerId,
      ...settings.toMap(),
    });
  }

  /// Resets all EQ bands to 0 dB (flat response).
  Future<void> resetEq() => setEq(EqSettings.flat);

  /// Sets a factory reverb [preset] with a wet/dry [wetMix] in `[0.0, 1.0]`.
  ///
  /// [wetMix] = `0.0` effectively bypasses the reverb. [ReverbPreset.none]
  /// always bypasses regardless of mix.
  Future<void> setReverb(ReverbPreset preset, {double wetMix = 0.0}) async {
    _checkNotDisposed();
    _currentReverbPreset = preset;
    _currentReverbWetMix = wetMix.clamp(0.0, 1.0);
    await _channel.invokeMethod<void>('setReverb', {
      'playerId': _playerId,
      'preset':   preset.name,
      'wetMix':   _currentReverbWetMix,
    });
  }

  /// Configures the dynamics compressor / limiter.
  ///
  /// Set `enabled: false` in [CompressorSettings] to bypass compression.
  Future<void> setCompressor(CompressorSettings settings) async {
    _checkNotDisposed();
    _currentCompressor = settings;
    await _channel.invokeMethod<void>('setCompressor', {
      'playerId': _playerId,
      ...settings.toMap(),
    });
  }

  // ── Spectrum Stream ────────────────────────────────────────────────────────

  /// Stream of [SpectrumData] emitted ~10 times per second while playing.
  ///
  /// Each event contains 256 normalised-magnitude bins from a 1024-point FFT.
  /// Use [SpectrumData.frequencyForBin] to map bins to Hz values.
  ///
  /// The stream is silent when the player is paused or stopped.
  Stream<SpectrumData> get spectrumStream {
    _checkNotDisposed();
    return _events
        .where((e) => e['type'] == 'spectrum')
        .map((e) => SpectrumData.fromMap(e));
  }

  // ── Export ─────────────────────────────────────────────────────────────────

  /// Exports the current loop region (or full file if no region is set) to
  /// [outputPath] as a WAV file.
  ///
  /// The export is the raw decoded audio **without** effects processing.
  /// The [format] parameter is reserved for future formats; currently only
  /// [ExportFormat.wav] is supported.
  ///
  /// Throws [PlatformException] if no file is loaded or write fails.
  Future<void> exportToFile(
    String outputPath, {
    ExportFormat format = ExportFormat.wav,
  }) async {
    _checkNotDisposed();
    await _channel.invokeMethod<void>('exportToFile', {
      'playerId':   _playerId,
      'outputPath': outputPath,
      'format':     format.name,
    });
  }

  // ── A-B Loop Points ────────────────────────────────────────────────────────

  double? _loopPointA;
  double? _loopPointB;

  /// Captures the current playback position as loop point A.
  Future<void> saveLoopPointA() async {
    _loopPointA = await currentPosition;
  }

  /// Captures the current playback position as loop point B.
  Future<void> saveLoopPointB() async {
    _loopPointB = await currentPosition;
  }

  /// Calls [setLoopRegion] with the saved A and B points.
  ///
  /// Does nothing if either point has not been saved, or if A >= B.
  Future<void> recallABLoop() async {
    final a = _loopPointA;
    final b = _loopPointB;
    if (a == null || b == null || a >= b) return;
    await setLoopRegion(a, b);
  }

  // ── Effects Preset ─────────────────────────────────────────────────────────

  EqSettings         _currentEq           = EqSettings.flat;
  ReverbPreset       _currentReverbPreset  = ReverbPreset.none;
  double             _currentReverbWetMix  = 0.0;
  CompressorSettings _currentCompressor    = const CompressorSettings(enabled: false);

  /// Captures the current EQ, reverb, and compressor state as a reusable [EffectsPreset].
  EffectsPreset captureEffectsPreset() => EffectsPreset(
        eq:            _currentEq,
        reverbPreset:  _currentReverbPreset,
        reverbWetMix:  _currentReverbWetMix,
        compressor:    _currentCompressor,
      );

  /// Applies all settings from [preset] in parallel.
  Future<void> applyEffectsPreset(EffectsPreset preset) async {
    await Future.wait([
      setEq(preset.eq),
      setReverb(preset.reverbPreset, wetMix: preset.reverbWetMix),
      setCompressor(preset.compressor),
    ]);
  }

  // ── Count-in ──────────────────────────────────────────────────────────────

  /// Starts [metronome] for [bars] bars, then calls [play] on this player at
  /// the precise moment the count-in ends.
  ///
  /// Pure-Dart: listens to [MetronomePlayer.beatStream] to count [bars] × beats,
  /// then calls [metronome.stop] and [play] on the next beat boundary.
  ///
  /// The metronome must be fully started (via [MetronomePlayer.start]) before
  /// calling this method. [bpmResult] is used to derive [beatsPerBar] when
  /// [MetronomePlayer.start]'s `beatsPerBar` has not been passed explicitly —
  /// pass `beatsPerBar` directly to override.
  ///
  /// ```dart
  /// final bpmResult = await player.bpmStream.first;
  /// await metronome.start(bpm: bpmResult.bpm, beatsPerBar: bpmResult.beatsPerBar, ...);
  /// await player.playAfterCountIn(metronome: metronome, bars: 1, beatsPerBar: bpmResult.beatsPerBar);
  /// ```
  Future<void> playAfterCountIn({
    required MetronomePlayer metronome,
    int bars = 1,
    int beatsPerBar = 4,
  }) async {
    _checkNotDisposed();
    final totalBeats = bars * beatsPerBar;
    var beatCount = 0;
    final completer = Completer<void>();
    late StreamSubscription<int> sub;
    sub = metronome.beatStream.listen((beat) async {
      beatCount++;
      if (beatCount >= totalBeats) {
        await sub.cancel();
        await metronome.stop();
        if (!_isDisposed) play();
        completer.complete();
      }
    });
    return completer.future;
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  /// Releases all native resources. This instance cannot be used after calling dispose.
  Future<void> dispose() async {
    _isDisposed = true;
    LoopAudioMaster._instances.remove(this);
    await _channel.invokeMethod<void>('dispose', {'playerId': _playerId});
  }

  // ── Private helpers ───────────────────────────────────────────────────────

  static double _dbToLinear(double db) => math.pow(10.0, db / 20.0).toDouble();

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

  RemoteCommand? _parseRemoteCommand(Map<Object?, Object?> e) {
    final cmd = e['command'] as String?;
    return switch (cmd) {
      'play'          => const RemotePlayCommand(),
      'pause'         => const RemotePauseCommand(),
      'stop'          => const RemoteStopCommand(),
      'nextTrack'     => const RemoteNextTrackCommand(),
      'previousTrack' => const RemotePreviousTrackCommand(),
      'seek'          => RemoteSeekCommand((e['position'] as num? ?? 0).toDouble()),
      _               => null,
    };
  }
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

  static final Set<LoopAudioPlayer> _instances = {};
  static double _masterVolume = 1.0;
  static double _masterPan    = 0.0;

  /// Current master volume (0.0–1.0). Default: `1.0`.
  static double get volume => _masterVolume;

  /// Current master pan (−1.0–1.0). Default: `0.0`.
  static double get pan => _masterPan;

  /// Scales all live [LoopAudioPlayer] instances multiplicatively.
  ///
  /// Each instance's effective volume becomes `localVolume × volume`.
  static Future<void> setVolume(double volume) async {
    _masterVolume = volume.clamp(0.0, 1.0);
    for (final inst in _instances) {
      if (!inst._isDisposed) await inst._applyEffectiveVolume();
    }
  }

  /// Shifts all live [LoopAudioPlayer] pans by [pan] (additive, clamped to ±1.0).
  static Future<void> setPan(double pan) async {
    _masterPan = pan.clamp(-1.0, 1.0);
    for (final inst in _instances) {
      if (!inst._isDisposed) await inst._applyEffectivePan();
    }
  }

  /// Resets master volume to 1.0 and pan to 0.0, then re-applies to all instances.
  static Future<void> reset() async {
    _masterVolume = 1.0;
    _masterPan    = 0.0;
    for (final inst in _instances) {
      if (!inst._isDisposed) {
        await inst._applyEffectiveVolume();
        await inst._applyEffectivePan();
      }
    }
  }

  /// Resets master state for use in tests only.
  @visibleForTesting
  static void resetForTesting() {
    _masterVolume = 1.0;
    _masterPan    = 0.0;
    _instances.clear();
  }
}
