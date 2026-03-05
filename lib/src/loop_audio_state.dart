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
