
## 0.0.6

### New features

* **`LoopAudioPlayer.setPitch(double semitones)`** — Shifts pitch independently of playback speed. `0.0` = no shift; range ±24 semitones (±2 octaves). On iOS uses `AVAudioUnitTimePitch.pitch` (cents). On Android uses `PlaybackParams.setPitch()` with a `2^(semitones/12)` multiplier. Fully orthogonal to `setPlaybackRate` — both can be set simultaneously.

* **`LoopAudioPlayer.seekCompleteStream`** — A `Stream<double>` that emits the seek position (seconds) once the native engine has rescheduled its buffers. Useful for confirming seeks before updating UI or synchronising players.

* **`LoopAudioPlayer.interruptionStream`** — A `Stream<InterruptionEvent>` that exposes system audio interruptions (phone calls, Siri, other apps taking audio focus). Emits `InterruptionType.began` when the player is automatically paused and `InterruptionType.ended` when the system releases focus. The player auto-pauses/resumes; listen to this stream to keep your UI in sync.

* **`LoopAudioPlayer.setNowPlayingInfo(NowPlayingInfo)` / `clearNowPlayingInfo()`** — Populates the iOS lock screen / Control Center (`MPNowPlayingInfoCenter`) and the Android media notification with track title, artist, album, duration, and optional cover art (`artworkBytes`). Once called, remote commands (play, pause, seek, next/previous) are delivered via `remoteCommandStream`.

* **`LoopAudioPlayer.remoteCommandStream`** — A `Stream<RemoteCommand>` of commands from the lock screen, headphone buttons, CarPlay, and the Android media notification. Subtypes: `RemotePlayCommand`, `RemotePauseCommand`, `RemoteStopCommand`, `RemoteNextTrackCommand`, `RemotePreviousTrackCommand`, `RemoteSeekCommand(position)`.

* **Background audio on Android** — `AudioPlaybackService`, a foreground `Service` with a `Notification.MediaStyle` notification, is automatically started when playback begins and stopped when it ends. This keeps the audio process alive when the screen is off. No changes required in the host app's manifest — the service is declared in the plugin's own manifest.

* **Background audio on iOS** — The example app's `Info.plist` now includes `UIBackgroundModes: [audio]`. Host apps must add this key themselves to enable background playback:
  ```xml
  <key>UIBackgroundModes</key>
  <array><string>audio</string></array>
  ```

### New types

* `InterruptionType` enum — `began`, `ended`
* `InterruptionEvent` class — wraps `InterruptionType`
* `RemoteCommand` sealed class — `RemotePlayCommand`, `RemotePauseCommand`, `RemoteStopCommand`, `RemoteNextTrackCommand`, `RemotePreviousTrackCommand`, `RemoteSeekCommand`
* `NowPlayingInfo` class — `title`, `artist`, `album`, `duration`, `artworkBytes`

### Native changes

* **iOS:** `LoopAudioEngine` gains `onInterruption`, `onSeekComplete` callbacks and `setPitch(_:)`. `FlutterGaplessLoopPlugin` sets up `MPRemoteCommandCenter` targets once and forwards commands as event-channel events. `MediaPlayer` framework added to podspec.
* **Android:** `LoopAudioEngine` gains `onInterruption`, `onSeekComplete` callbacks and `setPitch(Float)`. `applyPlaybackRate()` renamed to `applyPlaybackParams()` and updated to apply both rate and pitch in a single `PlaybackParams`. New `NowPlayingManager` manages `MediaSession` and notification. New `AudioPlaybackService` foreground service. Manifest gains `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_MEDIA_PLAYBACK` permissions and service declaration.

## 0.0.5

### New features

* **`LoopAudioPlayer.amplitudeStream`.** A new `Stream<AmplitudeEvent>` that emits real-time audio level data approximately 20 times per second while the player is in `PlayerState.playing`. Each `AmplitudeEvent` carries:
  * `rms` — root-mean-square level of the most recent audio buffer rendered by the native engine, in `[0.0, 1.0]`. Smooth signal; well-suited for VU meters.
  * `peak` — peak sample magnitude of the same buffer, in `[0.0, 1.0]`. Reacts faster than `rms`; use for peak-hold indicators.

  The stream emits no events when playback is paused or stopped. Both iOS and Android compute RMS and peak in the native render thread and post events via the existing `EventChannel`.

## 0.0.4

### New features

* **`LoopAudioMaster`.** A new static group-bus controller for all live `LoopAudioPlayer` instances. `setVolume` scales every instance multiplicatively (`effectiveVolume = localVolume × masterVolume`); `setPan` shifts every instance additively (`effectivePan = clamp(localPan + masterPan, −1, 1)`). `reset()` restores defaults and re-applies. Per-instance relative levels are preserved at the Dart layer — native engines receive only the final effective float.
* **`MetronomeMaster`.** Same group-bus pattern for all live `MetronomePlayer` instances.
* **`MetronomePlayer.setVolume` / `setPan`.** New per-instance volume and pan control on `MetronomePlayer`. Effective values are computed multiplicatively with `MetronomeMaster` before being sent to native. iOS: `AVAudioEngine.mainMixerNode.volume` / `.pan`, re-applied after every `setupAndPlay` rebuild. Android: `AudioTrack.setStereoVolume` via `panToGains`, re-applied after every `playBarBuffer` rebuild.

### Breaking changes

* `LoopAudioPlayer.setVolume` previously threw `ArgumentError` for values outside `[0.0, 1.0]`; it now silently clamps to be consistent with `setPan` and the new master API.

## 0.0.3

### New features

* **Multi-instance support.** Any number of `LoopAudioPlayer` and `MetronomePlayer` instances can run concurrently without cross-talk. Each instance receives a unique `playerId` (`'loop_N'` / `'metro_N'`) injected into every method channel call. Events are tagged with the same ID so the Dart layer filters them per-instance using a shared broadcast stream.
* **`MetronomePlayer`.** A new class that drives a sample-accurate click track independent of `LoopAudioPlayer`. Pre-generates a single-bar PCM buffer (accent on beat 0, regular clicks on beats 1…N-1) and loops it via the native hardware scheduler. Beat-tick events emitted per beat for UI synchronisation. API: `start`, `stop`, `setBpm`, `setBeatsPerBar`, `beatStream`, `dispose`.
* **`loadFromUrl(Uri)`.** Downloads and loads audio from an HTTP/HTTPS URL using the native networking stack (`URLSession` on iOS, `HttpURLConnection` on Android) — no third-party packages required.
* **`loadFromBytes(Uint8List)`.** Loads audio from in-memory bytes by writing to a temporary file, loading it, and cleaning up immediately.
* **Automatic time signature detection.** `BpmResult` now includes `beatsPerBar` (int) and `bars` (List\<double>) in addition to `bpm`, `confidence`, and `beats`.
* **Pitch-preserving playback rate** (`setPlaybackRate`) — time-stretch from 0.25× to 4×.

### Native engine changes

* **iOS:** `MetronomeEngine` uses its own `AVAudioEngine` + `AVAudioPlayerNode`. Bar buffer is built with `buildBarBuffer(bpm:beatsPerBar:)` and looped via `scheduleBuffer(.loops)`. Beat ticks fire via `DispatchSourceTimer` on `.main`. Plugin bridge now holds `[String: LoopAudioEngine]` and `[String: MetronomeEngine]` registries.
* **Android:** `MetronomeEngine` uses `AudioTrack MODE_STATIC` + `setLoopPoints` for hardware-level looping. Bar buffer is built via `buildBarBuffer()` (companion object — unit-testable). Beat ticks fire via `Handler`. Plugin bridge now holds `HashMap<String, LoopAudioEngine>` and `HashMap<String, MetronomeEngine>` registries.

### Breaking changes

* `loadFromUrl` no longer accepts an `httpClient` parameter (native networking is used instead).
* All method channel payloads now include a `playerId` key. Custom native-side integrations must be updated to extract and route by this key.

### Dependencies

* Removed `http: ^1.2.0` (no longer needed).

## 0.0.2

* `loadFromUrl` now downloads via the platform networking stack (`URLSession` on iOS, `HttpURLConnection` on Android) instead of Dart's HTTP client. No third-party packages required.
* URL scheme is validated natively (`http`/`https` only); invalid schemes return `PlatformException(INVALID_ARGS)`.
* Temp files for URL downloads use UUID names and are always cleaned up, including on coroutine cancellation (Android) and write failure (iOS).

## 0.0.1

* Initial release.
* Sample-accurate gapless looping on iOS (AVAudioEngine) and Android (AudioTrack).
* Configurable loop region (start/end in seconds).
* Optional equal-power crossfade between loop iterations.
* Volume control and seek support.
* Stereo pan control (`setPan`).
* Pitch-preserving playback rate / time-stretching (`setPlaybackRate`).
* Automatic BPM/tempo detection after every load (`bpmStream`, `BpmResult`).
* `stateStream`, `errorStream`, `routeChangeStream`, and `bpmStream` for reactive UI.
* Audio route change events (e.g. headphones unplugged).
