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
