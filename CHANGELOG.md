
## 0.0.8

### New features (Tier 3 — Production Audio FX)

* **3-band parametric EQ** (`setEq(EqSettings)`, `resetEq()`) — Low-shelf at 80 Hz, parametric peak at 1 kHz, high-shelf at 10 kHz. Each band ±12 dB. On iOS uses `AVAudioUnitEQ`; on Android uses `android.media.audiofx.Equalizer` bound to the AudioTrack session.

* **Reverb presets** (`setReverb(ReverbPreset, {wetMix})`) — Eight presets: `none`, `smallRoom`, `mediumRoom`, `largeRoom`, `mediumHall`, `largeHall`, `plate`, `cathedral`. On iOS uses `AVAudioUnitReverb.loadFactoryPreset`; on Android uses `android.media.audiofx.PresetReverb`.

* **Compressor/limiter** (`setCompressor(CompressorSettings)`) — Configurable threshold (dBFS), makeup gain (dB), attack (ms), and release (ms). On iOS uses `AVAudioUnitEffect` wrapping `kAudioUnitSubType_DynamicsProcessor`; on Android uses a pure-software 1-pole IIR envelope follower applied per write chunk.

* **Real-time FFT spectrum** (`spectrumStream`) — `Stream<SpectrumData>` emitting 256-bin normalised magnitude data at ~10 Hz while playing. On iOS computed with `vDSP_DFT_ExecuteD` (Accelerate framework); on Android uses an iterative Cooley-Tukey FFT in the write thread. Use `SpectrumData.frequencyForBin(bin)` to map a bin index to Hz.

* **Export to WAV** (`exportToFile(outputPath)`) — Writes the current loop region (or full file if no region set) as a 32-bit float PCM WAV file to an absolute path on the device. Runs on a background thread; the returned `Future` completes on the Flutter isolate.

* **A-B loop points** (`saveLoopPointA()`, `saveLoopPointB()`, `recallABLoop()`) — Pure Dart: captures the current playback position as loop point A or B, and calls `setLoopRegion(A, B)` when both are set and A < B.

* **Effects preset** (`captureEffectsPreset()`, `applyEffectsPreset(preset)`) — Pure Dart: snapshot all active effect settings into an `EffectsPreset` and restore them in one call.

### New types

* `EqSettings` — `bass`, `mid`, `treble` (dB), static `flat`, `toMap()`
* `ReverbPreset` enum — 8 values
* `CompressorSettings` — `enabled`, `thresholdDb`, `makeupGainDb`, `attackMs`, `releaseMs`
* `SpectrumData` — `binCount`, `magnitudes`, `sampleRate`, `frequencyForBin(bin)`
* `ExportFormat` enum — `wav`
* `EffectsPreset` — `eq`, `reverbPreset`, `reverbWetMix`, `compressor`, static `bypass`

### Native changes

* **iOS:** `LoopAudioEngine` adds `eqNode` (`AVAudioUnitEQ`, 3 bands), `reverbNode` (`AVAudioUnitReverb`), `compressorNode` (`AVAudioUnitEffect`/DynamicsProcessor) always attached in the graph and bypassed by default. `installAmplitudeTap` extended to emit spectrum events via `vDSP_DFT_ExecuteD` (Accelerate) at ~10 Hz. New methods: `setEq`, `setReverb`, `setCompressor`, `exportToFile`. `FlutterGaplessLoopPlugin` wires `onSpectrum` callback and routes the four new method calls.

* **Android:** `LoopAudioEngine` adds `Equalizer` + `PresetReverb` AudioFx effects bound to the AudioTrack session via `reattachEffects()`. Software compressor applied per write chunk in `applyCompressor()`. Cooley-Tukey FFT computed in `computeSpectrum()` at ~10 Hz. New methods: `setEq`, `setReverb`, `setCompressor`, `exportToFile`, `writeWavFile`. `FlutterGaplessLoopPlugin` wires `onSpectrum` and routes the four new method calls. podspec updated with `AudioToolbox` and `Accelerate` frameworks.

## 0.0.7

### New features

* **`LoopSyncGroup`** — Start any number of `LoopAudioPlayer` instances simultaneously with sample-accurate synchronisation. On iOS each player's `AVAudioPlayerNode` is scheduled to a shared `AVAudioTime` (via `mach_absolute_time()`); on Android all write threads sleep until a shared `SystemClock.uptimeMillis()` target. Usage: `await LoopSyncGroup([drums, bass]).playAll()`.

* **Beat-synced seek** — Three pure-Dart helpers using the `BpmResult` from `bpmStream`:
  - `seekToNearestBeat(position, bpmResult)` — seeks to the beat closest to a given position.
  - `seekToBeat(index, bpmResult)` — seeks to beat number `index` (zero-based).
  - `seekToBar(index, bpmResult)` — seeks to bar number `index` (zero-based).

* **Count-in before play** (`playAfterCountIn`) — Waits for a running `MetronomePlayer` to complete `bars` bars, then calls `play()` at the precise beat boundary. Requires an already-started `MetronomePlayer`.

* **Fade in / fade out / fade to** — Three methods for click-free volume ramps:
  - `fadeTo(targetVolume, {duration})` — ramp to any target volume.
  - `fadeIn({duration})` — ramp from silence to the current local volume.
  - `fadeOut({duration})` — ramp from the current level to silence.
  The ramp is driven natively (iOS: `DispatchSourceTimer` at 100 Hz; Android: coroutine `delay` at 100 Hz) so there is no Flutter-thread overhead.

* **Waveform data extraction** (`getWaveformData({resolution})`) — Returns a `WaveformData` with `resolution` peak-amplitude data points in `[0.0, 1.0]`. Computed natively on a background thread. Suitable for drawing a waveform overview or scrubber.

* **Silence detection / trim** — Two methods:
  - `detectSilence({thresholdDb})` — returns a `SilenceInfo` with `start` and `end` seconds of the non-silent region.
  - `trimSilence({thresholdDb})` — calls `setLoopRegion` automatically with the result of `detectSilence`. Non-destructive; does not modify the underlying PCM.

* **LUFS loudness analysis & normalisation** — Two methods:
  - `getLoudness()` — returns `LoudnessInfo.lufs` using the EBU R128 / ITU-R BS.1770-4 K-weighting two-biquad-stage algorithm.
  - `normaliseLoudness({targetLufs})` — computes the gain delta between the measured LUFS and `targetLufs` (default −14 LUFS) and applies it via `setVolume`. Non-destructive.

### New types

* `WaveformData` class — `resolution`, `peaks` (List\<double>)
* `SilenceInfo` class — `start`, `end`, `duration`
* `LoudnessInfo` class — `lufs`
* `LoopSyncGroup` class — `players`, `playAll()`, `pauseAll()`, `stopAll()`

### Native changes

* **iOS:** `LoopAudioEngine` gains `fadeTo(targetVolume:duration:startFromSilence:)`, `getWaveformData(resolution:)`, `detectSilence(thresholdDb:)`, `getLoudness()`, and `syncPlay(hostTime:)`. New `LoudnessAnalyser.swift` implements EBU R128 K-weighting biquad filter. `FlutterGaplessLoopPlugin` handles `syncPlay` before the per-player guard via `handleSyncPlay`.
* **Android:** `LoopAudioEngine` gains `fadeTo()`, `getWaveformData()`, `detectSilence()`, `getLoudness()`, and `syncPlay()` / `startSyncWriteThread()`. New `LoudnessAnalyser.kt` mirrors the Swift implementation. `FlutterGaplessLoopPlugin` handles `syncPlay` via `handleSyncPlay`.

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
