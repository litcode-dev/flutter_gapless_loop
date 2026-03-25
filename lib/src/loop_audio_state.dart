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

/// Carries the reason for an audio route change from the native layer.
class RouteChangeEvent {
  /// The reason this route change occurred.
  final RouteChangeReason reason;

  /// Creates a [RouteChangeEvent] with the given [reason].
  const RouteChangeEvent(this.reason);
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

// ── Tier 1: NowPlayingInfo ──────────────────────────────────────────────────

/// Metadata for the iOS MPNowPlayingInfoCenter and Android media notification.
class NowPlayingInfo {
  final String? title;
  final String? artist;
  final String? album;
  final Uint8List? artworkBytes;
  final String artworkMimeType;
  final double? duration;
  final double? elapsed;

  const NowPlayingInfo({
    this.title,
    this.artist,
    this.album,
    this.artworkBytes,
    this.artworkMimeType = 'image/jpeg',
    this.duration,
    this.elapsed,
  });
}

// ── Tier 1: RemoteCommand ──────────────────────────────────────────────────

/// Commands that can be received from the lock screen, headphones, CarPlay,
/// or Android notification.
enum RemoteCommand {
  play,
  pause,
  stop,
  nextTrack,
  previousTrack,
  seekForward,
  seekBackward,
  changePlaybackPosition,
  togglePlayPause,
}

/// An event from the remote command center (lock screen, headphones, CarPlay).
class RemoteCommandEvent {
  final RemoteCommand command;

  /// Position in seconds, only set for [RemoteCommand.changePlaybackPosition].
  final double? position;

  const RemoteCommandEvent(this.command, {this.position});
}

// ── Tier 1: Interruption ──────────────────────────────────────────────────

/// Whether an audio interruption began or ended.
enum InterruptionType { began, ended }

/// An audio interruption event (phone call, Siri, focus loss).
class InterruptionEvent {
  final InterruptionType type;

  /// `true` when the system recommends resuming after an ended interruption.
  final bool shouldResume;

  const InterruptionEvent(this.type, {this.shouldResume = false});
}

// ── Tier 2: SilenceRegion ─────────────────────────────────────────────────

/// A contiguous region of silence detected in the loaded audio file.
class SilenceRegion {
  /// Start of the silent region in seconds.
  final double start;

  /// End of the silent region in seconds.
  final double end;

  const SilenceRegion({required this.start, required this.end});

  /// Duration of the silent region in seconds.
  double get duration => end - start;

  factory SilenceRegion.fromMap(Map<Object?, Object?> m) => SilenceRegion(
    start: (m['start'] as num).toDouble(),
    end:   (m['end']   as num).toDouble(),
  );
}

// ── Tier 3: EQ / Reverb / Compressor / Spectrum / Export / Effects Preset ──

/// 3-band equaliser settings.
class EqSettings {
  /// Low-shelf gain in dB at 80 Hz. Range: ±12 dB.
  final double lowGainDb;

  /// Peaking gain in dB at 1 kHz. Range: ±12 dB.
  final double midGainDb;

  /// High-shelf gain in dB at 10 kHz. Range: ±12 dB.
  final double highGainDb;

  const EqSettings({
    this.lowGainDb  = 0,
    this.midGainDb  = 0,
    this.highGainDb = 0,
  });

  Map<String, double> toMap() => {
    'low':  lowGainDb,
    'mid':  midGainDb,
    'high': highGainDb,
  };
}

/// Filter type for the cutoff filter.
enum FilterType {
  /// Low-pass filter: passes frequencies below [CutoffFilterSettings.cutoffHz].
  lowPass,

  /// High-pass filter: passes frequencies above [CutoffFilterSettings.cutoffHz].
  highPass,
}

/// Settings for a single-pole cutoff (low-pass or high-pass) filter.
///
/// Applied after the 3-band EQ in the signal chain.
class CutoffFilterSettings {
  /// Whether to use a low-pass or high-pass filter.
  final FilterType type;

  /// Cutoff frequency in Hz. Range: 20–20000 Hz.
  ///
  /// Defaults to 20000 Hz for [FilterType.lowPass] (effectively transparent)
  /// and 20 Hz for [FilterType.highPass].
  final double cutoffHz;

  /// Resonance (Q factor). Range: 0.1–10.0. Default 0.707 (Butterworth, no resonance peak).
  final double resonance;

  const CutoffFilterSettings({
    this.type      = FilterType.lowPass,
    this.cutoffHz  = 20000.0,
    this.resonance = 0.707,
  });

  Map<String, dynamic> toMap() => {
    'type':      type.index,
    'cutoffHz':  cutoffHz.clamp(20.0, 20000.0),
    'resonance': resonance.clamp(0.1, 10.0),
  };
}

/// Built-in reverb room presets.
enum ReverbPreset {
  smallRoom,
  mediumRoom,
  largeRoom,
  mediumHall,
  largeHall,
  plate,
  cathedral,
}

/// Dynamic-range compressor settings.
class CompressorSettings {
  /// Threshold in dB above which gain reduction is applied. Default: −20 dB.
  final double threshold;

  /// Make-up gain in dB applied after compression. Default: 0 dB.
  final double makeupGain;

  /// Attack time in milliseconds. Default: 10 ms.
  final double attackMs;

  /// Release time in milliseconds. Default: 100 ms.
  final double releaseMs;

  const CompressorSettings({
    this.threshold  = -20,
    this.makeupGain = 0,
    this.attackMs   = 10,
    this.releaseMs  = 100,
  });

  Map<String, double> toMap() => {
    'threshold':  threshold,
    'makeupGain': makeupGain,
    'attackMs':   attackMs,
    'releaseMs':  releaseMs,
  };
}

/// Real-time FFT spectrum data emitted by [LoopAudioPlayer.spectrumStream].
class SpectrumData {
  /// 256 normalised [0, 1] magnitude bins from low to high frequency.
  final Float32List magnitudes;

  const SpectrumData(this.magnitudes);

  factory SpectrumData.fromList(List<Object?> raw) {
    final f = Float32List(raw.length);
    for (int i = 0; i < raw.length; i++) {
      f[i] = (raw[i] as num).toDouble().clamp(0.0, 1.0);
    }
    return SpectrumData(f);
  }
}

/// Output format for [LoopAudioPlayer.exportToFile].
enum ExportFormat {
  /// 32-bit float IEEE PCM WAV.
  wav32bit,

  /// 16-bit integer PCM WAV.
  wav16bit,
}

/// A snapshot of all active DSP effect settings, for save/restore.
class EffectsPreset {
  final EqSettings eq;
  final ReverbPreset reverb;
  final double reverbWetMix;
  final CompressorSettings compressor;
  final CutoffFilterSettings? cutoff;

  const EffectsPreset({
    required this.eq,
    required this.reverb,
    required this.reverbWetMix,
    required this.compressor,
    this.cutoff,
  });
}

/// A pair of A-B loop points set by [LoopAudioPlayer.saveLoopPointA] /
/// [LoopAudioPlayer.saveLoopPointB].
class LoopPoints {
  final double? pointA;
  final double? pointB;

  const LoopPoints({this.pointA, this.pointB});

  /// `true` when both points have been set.
  bool get isComplete => pointA != null && pointB != null;
}
