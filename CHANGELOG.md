
## 0.0.4

### New platforms

* **macOS support.** Full implementation using `AVAudioEngine` + `AVAudioUnitTimePitch`, matching the iOS engine. Audio session is replaced by `AVAudioEngineConfigurationChange` notifications. Minimum macOS version: 11.0.
* **Windows support.** Full implementation using XAudio2 2.9 (Windows 10+) + MediaFoundation decoding. All four playback modes (full/region × with/without crossfade) are supported. Beat-accurate metronome via XAudio2 + `std::chrono` timer. BPM/time-signature detection ported in C++. Audio device changes handled via `IMMNotificationClient`.

### Bug fixes

* **Hot-restart guard.** A `static bool _didClearAll` flag fires `clearAll` on the native engine map the first time a `LoopAudioPlayer` or `MetronomePlayer` is constructed after a Dart hot restart. This prevents stale native engines from a previous Dart generation leaking into the new session. All four native platforms (iOS, Android, macOS, Windows) handle the `clearAll` call on both the loop and metronome channels.
* **GC-based dispose safety net.** `LoopAudioPlayer` and `MetronomePlayer` now register a `Finalizer<String>` that fires a native `dispose` call if the Dart object is garbage-collected without an explicit `dispose()`. Instances are tracked in a `Set<WeakReference<T>>` so they do not prevent collection. The `_forEachLive` helper in `LoopAudioMaster` / `MetronomeMaster` lazily removes stale weak references during group-bus operations.

### Performance improvements

* **Android: async `MediaCodec` decode.** `AudioFileLoader` now uses `MediaCodec.Callback` (async mode) instead of a synchronous poll loop with a 10 ms dequeue timeout. Codec buffer callbacks fire immediately when the hardware is ready, eliminating hundreds of unnecessary spin cycles on longer files. Biggest win on files ≥ 10 seconds.
* **Android: pre-allocated PCM buffer.** The decoded PCM output is now pre-allocated from the track duration estimate (+ 10% headroom for encoder padding) and written into directly, replacing the previous `ArrayList<FloatArray>` collect-then-copy pattern. This cuts peak memory usage and eliminates one full-size `FloatArray` copy per load.

### New features

* **`LoopAudioPlayer.amplitudeStream`.** A new `Stream<AmplitudeEvent>` that emits real-time audio level data approximately 20 times per second while the player is in `PlayerState.playing`. Each `AmplitudeEvent` carries:
  * `rms` — root-mean-square level of the most recent audio buffer rendered by the native engine, in `[0.0, 1.0]`. Smooth signal; well-suited for VU meters.
  * `peak` — peak sample magnitude of the same buffer, in `[0.0, 1.0]`. Reacts faster than `rms`; use for peak-hold indicators.

  The stream emits no events when playback is paused or stopped. Both iOS and Android compute RMS and peak in the native render thread and post events via the existing `EventChannel`.

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
