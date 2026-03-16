import 'dart:typed_data';

/// Playback state of the [LoopAudioPlayer].
enum PlayerState {
  /// No file has been loaded. Initial state.
  idle,

  /// A file is currently being read and decoded into memory.
  loading,

  /// A file has been loaded and the engine is ready to play.
  ready,

  /// Audio is actively playing and looping.
  playing,

  /// Playback is paused. Can be resumed without reloading.
  paused,

  /// Playback has been stopped. Seek position is reset.
  stopped,

  /// An unrecoverable error occurred. Check [LoopAudioPlayer.errorStream].
  error,
}

/// Describes why an audio route change occurred (e.g. headphones unplugged).
enum RouteChangeReason {
  /// The previously active audio output device (e.g. headphones) was removed.
  headphonesUnplugged,

  /// The AVAudioSession category changed, triggering a route re-evaluation.
  categoryChange,

  /// A route change occurred for a reason not explicitly handled by this plugin.
  unknown,
}

/// Whether a system audio interruption began or ended.
enum InterruptionType {
  /// The interruption began (e.g. phone call, Siri, another app takes audio focus).
  began,

  /// The interruption ended (the system released audio focus back to this app).
  ended,
}

/// Carries the reason for an audio route change from the native layer.
class RouteChangeEvent {
  /// The reason this route change occurred.
  final RouteChangeReason reason;

  /// Creates a [RouteChangeEvent] with the given [reason].
  const RouteChangeEvent(this.reason);
}

/// Emitted by [LoopAudioPlayer.interruptionStream] when the system interrupts
/// or resumes audio (phone calls, Siri, other apps requesting audio focus).
///
/// On iOS this maps to `AVAudioSession.interruptionNotification`.
/// On Android this maps to `AudioManager.AUDIOFOCUS_LOSS_TRANSIENT`.
///
/// The player automatically pauses on [InterruptionType.began] and, where the
/// system permits, resumes on [InterruptionType.ended].
class InterruptionEvent {
  /// Whether the interruption began or ended.
  final InterruptionType type;

  const InterruptionEvent(this.type);
}

/// A remote-control command received from the system lock screen, headphone
/// buttons, CarPlay, or Android media notification.
///
/// Emitted by [LoopAudioPlayer.remoteCommandStream].
/// The app is responsible for acting on these commands (e.g. calling
/// [LoopAudioPlayer.play] when [RemotePlayCommand] is received).
sealed class RemoteCommand {
  const RemoteCommand();
}

/// The user pressed the play button on the lock screen or headphones.
class RemotePlayCommand extends RemoteCommand {
  const RemotePlayCommand();
}

/// The user pressed the pause button.
class RemotePauseCommand extends RemoteCommand {
  const RemotePauseCommand();
}

/// The user pressed stop.
class RemoteStopCommand extends RemoteCommand {
  const RemoteStopCommand();
}

/// The user pressed next-track.
class RemoteNextTrackCommand extends RemoteCommand {
  const RemoteNextTrackCommand();
}

/// The user pressed previous-track.
class RemotePreviousTrackCommand extends RemoteCommand {
  const RemotePreviousTrackCommand();
}

/// The user seeked to [position] seconds via the lock screen scrubber.
class RemoteSeekCommand extends RemoteCommand {
  /// Target position in seconds.
  final double position;
  const RemoteSeekCommand(this.position);
}

/// Metadata displayed on the iOS lock screen / Control Center and the Android
/// media notification.
///
/// Pass to [LoopAudioPlayer.setNowPlayingInfo] to populate the system media UI.
/// All fields are optional — supply only what is relevant to your content.
class NowPlayingInfo {
  /// Track title shown on the lock screen.
  final String? title;

  /// Artist name.
  final String? artist;

  /// Album name.
  final String? album;

  /// Total duration of the track in seconds.
  ///
  /// Required for the lock screen scrubber to display correctly on iOS
  /// and for the Android notification progress bar.
  final double? duration;

  /// Cover art as raw PNG or JPEG bytes.
  ///
  /// Displayed as album artwork on the lock screen (iOS) and in the
  /// media notification (Android).
  final Uint8List? artworkBytes;

  const NowPlayingInfo({
    this.title,
    this.artist,
    this.album,
    this.duration,
    this.artworkBytes,
  });
}

/// Real-time audio amplitude (level) emitted by [LoopAudioPlayer.amplitudeStream].
///
/// Emitted approximately 20 times per second while the player is in [PlayerState.playing].
/// Both values are in [0.0, 1.0] where 0.0 is silence and 1.0 is full scale.
class AmplitudeEvent {
  /// Root-mean-square level of the current audio buffer.
  ///
  /// A good choice for driving a smooth VU meter.
  final double rms;

  /// Peak sample magnitude of the current audio buffer.
  ///
  /// Reacts faster than [rms]; use for peak-hold indicators.
  final double peak;

  const AmplitudeEvent({required this.rms, required this.peak});

  /// Creates an [AmplitudeEvent] from the raw map sent by the native event channel.
  factory AmplitudeEvent.fromMap(Map<Object?, Object?> map) => AmplitudeEvent(
    rms:  (map['rms']  as num? ?? 0).toDouble().clamp(0.0, 1.0),
    peak: (map['peak'] as num? ?? 0).toDouble().clamp(0.0, 1.0),
  );
}

/// Downsampled peak amplitudes returned by [LoopAudioPlayer.getWaveformData].
///
/// Each element in [peaks] is the maximum absolute sample magnitude in its
/// corresponding segment, in `[0.0, 1.0]`. The number of segments equals the
/// [resolution] passed to [LoopAudioPlayer.getWaveformData].
class WaveformData {
  /// Number of data points (segments). Equals the resolution requested.
  final int resolution;

  /// Peak amplitude for each segment, in `[0.0, 1.0]`.
  final List<double> peaks;

  const WaveformData({required this.resolution, required this.peaks});

  factory WaveformData.fromMap(Map<Object?, Object?> map) {
    final raw = (map['peaks'] as List<Object?>?) ?? const [];
    return WaveformData(
      resolution: (map['resolution'] as int? ?? raw.length),
      peaks: raw.map((e) => (e as num).toDouble().clamp(0.0, 1.0)).toList(),
    );
  }
}

/// Result of [LoopAudioPlayer.detectSilence].
///
/// Describes the non-silent region within the loaded audio file.
/// Use [start] and [end] with [LoopAudioPlayer.setLoopRegion] (or call
/// [LoopAudioPlayer.trimSilence] which does this automatically).
class SilenceInfo {
  /// Start of the non-silent region in seconds.
  final double start;

  /// End of the non-silent region in seconds.
  final double end;

  /// Duration of the non-silent region in seconds.
  double get duration => end - start;

  const SilenceInfo({required this.start, required this.end});

  factory SilenceInfo.fromMap(Map<Object?, Object?> map) => SilenceInfo(
        start: (map['start'] as num? ?? 0).toDouble(),
        end:   (map['end']   as num? ?? 0).toDouble(),
      );
}

/// Integrated loudness result returned by [LoopAudioPlayer.getLoudness].
///
/// Uses the EBU R128 / ITU-R BS.1770-4 K-weighting algorithm.
class LoudnessInfo {
  /// Integrated loudness in LUFS (Loudness Units relative to Full Scale).
  ///
  /// A typical streaming target is -14 LUFS. Silence returns `-inf` (represented
  /// as `-100.0` for practical purposes).
  final double lufs;

  const LoudnessInfo({required this.lufs});

  factory LoudnessInfo.fromMap(Map<Object?, Object?> map) =>
      LoudnessInfo(lufs: (map['lufs'] as num? ?? -100).toDouble());
}

// ─────────────────────────────────────────────────────────────────────────────
// Tier 3 types
// ─────────────────────────────────────────────────────────────────────────────

/// 3-band equaliser settings used by [LoopAudioPlayer.setEq].
///
/// All gains are in dB and clamped to `[-12.0, +12.0]` when applied.
/// - [bass] controls a low-shelf filter centred at 80 Hz.
/// - [mid] controls a parametric peak filter centred at 1 kHz.
/// - [treble] controls a high-shelf filter centred at 10 kHz.
class EqSettings {
  final double bass;
  final double mid;
  final double treble;

  const EqSettings({this.bass = 0.0, this.mid = 0.0, this.treble = 0.0});

  /// Neutral (flat) EQ with all bands at 0 dB.
  static const flat = EqSettings();

  Map<String, double> toMap() => {'bass': bass, 'mid': mid, 'treble': treble};
}

/// Factory reverb presets used by [LoopAudioPlayer.setReverb].
///
/// On iOS these map to [AVAudioUnitReverbPreset] values.
/// On Android these map to [android.media.audiofx.PresetReverb] preset IDs.
enum ReverbPreset {
  none,
  smallRoom,
  mediumRoom,
  largeRoom,
  mediumHall,
  largeHall,
  plate,
  cathedral,
}

/// Compressor/limiter settings used by [LoopAudioPlayer.setCompressor].
class CompressorSettings {
  /// Whether the compressor is active. Default: `true`.
  final bool enabled;

  /// Gain-reduction threshold in dBFS. Range: -40 to 0. Default: `-20.0`.
  final double thresholdDb;

  /// Makeup gain in dB applied after compression. Range: -20 to +20. Default: `0.0`.
  final double makeupGainDb;

  /// Attack time in milliseconds. Range: 1–200 ms. Default: `10.0`.
  final double attackMs;

  /// Release time in milliseconds. Range: 10–3000 ms. Default: `100.0`.
  final double releaseMs;

  const CompressorSettings({
    this.enabled     = true,
    this.thresholdDb = -20.0,
    this.makeupGainDb = 0.0,
    this.attackMs    = 10.0,
    this.releaseMs   = 100.0,
  });

  Map<String, dynamic> toMap() => {
    'enabled':      enabled,
    'thresholdDb':  thresholdDb,
    'makeupGainDb': makeupGainDb,
    'attackMs':     attackMs,
    'releaseMs':    releaseMs,
  };
}

/// Real-time FFT spectrum data emitted by [LoopAudioPlayer.spectrumStream].
///
/// Emitted approximately 10 times per second while the player is in
/// [PlayerState.playing]. [magnitudes] contains [binCount] values in
/// `[0.0, 1.0]` (normalised linear magnitude).
///
/// Use [frequencyForBin] to map a bin index to a Hz value.
class SpectrumData {
  /// Number of frequency bins. Typically 256.
  final int binCount;

  /// Normalised magnitude for each bin, in `[0.0, 1.0]`.
  final List<double> magnitudes;

  /// Sample rate of the source audio, needed for frequency calculations.
  final double sampleRate;

  const SpectrumData({
    required this.binCount,
    required this.magnitudes,
    required this.sampleRate,
  });

  /// Centre frequency in Hz for bin [bin].
  ///
  /// Based on an FFT of size `binCount * 4` (i.e. 1024 for 256 bins):
  ///   `frequency = bin × sampleRate / (binCount × 2)`
  double frequencyForBin(int bin) => bin * sampleRate / (binCount * 2.0);

  factory SpectrumData.fromMap(Map<Object?, Object?> map) {
    final raw = (map['magnitudes'] as List<Object?>?) ?? const [];
    return SpectrumData(
      binCount:   (map['binCount']  as int?    ?? raw.length),
      sampleRate: (map['sampleRate'] as num?   ?? 44100).toDouble(),
      magnitudes: raw.map((e) => (e as num).toDouble().clamp(0.0, 1.0)).toList(),
    );
  }
}

/// Export format for [LoopAudioPlayer.exportToFile].
enum ExportFormat {
  /// Uncompressed PCM WAV file. Lossless, universally compatible.
  wav,
}

/// A snapshot of all active audio effects settings, created by
/// [LoopAudioPlayer.captureEffectsPreset] and applied via
/// [LoopAudioPlayer.applyEffectsPreset].
class EffectsPreset {
  final EqSettings      eq;
  final ReverbPreset    reverbPreset;
  final double          reverbWetMix;     // 0.0–1.0
  final CompressorSettings compressor;

  const EffectsPreset({
    this.eq           = EqSettings.flat,
    this.reverbPreset = ReverbPreset.none,
    this.reverbWetMix = 0.0,
    this.compressor   = const CompressorSettings(enabled: false),
  });

  /// Completely flat / bypass preset — no EQ, no reverb, no compression.
  static const bypass = EffectsPreset();
}

/// The result of BPM/tempo detection on a loaded audio file.
///
/// Emitted via [LoopAudioPlayer.bpmStream] after every successful load.
class BpmResult {
  /// Estimated tempo in beats per minute. `0.0` if detection was skipped
  /// (audio shorter than 2 seconds or completely silent).
  final double bpm;

  /// Confidence of the estimate in [0.0, 1.0]. Values above 0.5 indicate
  /// reliable detection.
  final double confidence;

  /// Beat timestamps in seconds from the start of the file.
  final List<double> beats;

  /// Estimated beats per bar (time signature numerator). `0` if unknown
  /// (low confidence or audio too short). Typical values: 2, 3, 4, 6, 7.
  final int beatsPerBar;

  /// Bar start timestamps in seconds. Empty if [beatsPerBar] is `0`.
  final List<double> bars;

  const BpmResult({
    required this.bpm,
    required this.confidence,
    required this.beats,
    this.beatsPerBar = 0,
    this.bars = const [],
  });

  /// Creates a [BpmResult] from the raw map sent by the native event channel.
  factory BpmResult.fromMap(Map<Object?, Object?> map) => BpmResult(
    bpm:         (map['bpm'] as num? ?? 0).toDouble(),
    confidence:  (map['confidence'] as num? ?? 0).toDouble(),
    beats: ((map['beats'] as List<Object?>?) ?? const [])
        .map((e) => (e as num).toDouble())
        .toList(),
    beatsPerBar: (map['beatsPerBar'] as int? ?? 0),
    bars: ((map['bars'] as List<Object?>?) ?? const [])
        .map((e) => (e as num).toDouble())
        .toList(),
  );
}
