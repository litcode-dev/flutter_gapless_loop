
## 0.0.8

### Bug fixes

* **iOS: `clamped(to:)` extension added.** `Float.clamped(to:)` is not publicly available in the Swift standard library — the `package` protection level on the stdlib internal made calls to it fail with *'clamped' is inaccessible due to 'package' protection level*. A `private extension Comparable` providing `clamped(to:)` is now defined in `LoopAudioEngine.swift`.

* **iOS: `trimSilence` spurious `return` removed.** The `guard` in `trimSilence` incorrectly used `return [] as Void`, which the compiler rejected as *unexpected non-void return value in void function*. Fixed to a bare `return`.

* **iOS: `kDynamicsProcessorParam_OverallGain` used in `setCompressor`.** `kDynamicsProcessorParam_MasterGain` was removed in iOS 7; its Swift-visible name is now `kDynamicsProcessorParam_OverallGain`. Updated accordingly.

## 0.0.7

### Bug fixes

* **iOS: `loadFile` runs on a background queue.** `AVAudioFile(forReading:)` and `buffer.read(into:)` are synchronous I/O calls. Previously both the `'load'` and `'loadAsset'` method channel handlers invoked `loadFile` directly on the platform channel handler thread (the main thread), blocking the Flutter UI for the full duration of audio decoding. Both handlers now dispatch `loadFile` to `DispatchQueue.global(qos: .userInitiated)` and return the Flutter result on `DispatchQueue.main`. The `'loadUrl'` handler is unaffected — its `loadFile` call already runs inside a `URLSession.dataTask` completion block on a background thread.

* **iOS: `sessionConfigured` access level corrected.** `LoopAudioEngine.sessionConfigured` was declared `private static` in `LoopAudioEngine.swift` but accessed from `FlutterGaplessLoopPlugin.swift` in the same module. In Swift, `private` is file-scoped — this cross-file reference would fail to compile. Changed to `internal static` (Swift's default), which is correct: the property is reset by the plugin on `detachFromEngine` (hot restart) and must be visible within the module without being part of the public API.

* **Web: `AudioContext` auto-resumed on `play()`.** Browsers suspend the `AudioContext` until a user gesture occurs. Calling `play()` without prior interaction would silently fail because the context remained `suspended`. `play()` now calls `AudioContext.resume()` before scheduling playback, conforming to the Web Audio API autoplay policy.

* **Web: `setCrossfadeDuration` throws `UnsupportedError`.** The web implementation previously ignored crossfade duration changes silently. It now throws `UnsupportedError('setCrossfadeDuration is not supported on web')` so callers receive explicit feedback.

* **Dart/IO: temp file names include a random nonce.** `loadFromBytes` and `loadFromUrl` write audio data to a temporary file whose name previously used only a millisecond timestamp, creating a collision window under concurrent calls. The name now includes a 32-bit random suffix, making collisions practically impossible.

### New API

* **`LoopAudioPlayer.isDisposed`** — synchronous `bool` getter. Returns `true` after `dispose()` has been called. Use this to guard cleanup code or check lifecycle state without async overhead.

* **`LoopAudioPlayer.lastKnownPosition`** — synchronous `double` getter (seconds). Updated by `seek()` and reset to `0.0` by `stop()`. Use this for non-critical UI reads that can tolerate a slightly stale value; use `currentPosition` (async) when an exact native-layer position is required.


### Build system

* **Swift Package Manager (SPM) support (iOS and macOS).** iOS and macOS Swift sources are now unified in `darwin/Classes/` and exposed as an SPM package (`darwin/Package.swift`). On Flutter 3.27+, SPM is the default build system for both platforms — no configuration flag required. CocoaPods remains supported as a fallback. This consolidation eliminates ~1700 lines of duplicated Swift source.

### Breaking changes

* Minimum Flutter version raised from `3.3.0` to `3.27.0`. Apps targeting an earlier Flutter release should pin to `flutter_gapless_loop: ^0.0.6`.

## 0.0.6

### Bug fixes

* **Multi-engine `AVAudioSession` conflict (iOS).** When two `LoopAudioPlayer` instances are used concurrently (e.g. a drone pad and a loop player), every `loadFile` call on a new engine previously re-ran `AVAudioSession.setCategory(.playback) + setActive(true)` on the shared session. Reconfiguring the shared `AVAudioSession` while another `AVAudioEngine` is actively running triggers an `AVAudioEngineConfigurationChange` notification that invalidates the running engine, causing the second player's `engine.start()` to fail. Fixed by guarding `setCategory`/`setActive` behind a `private static var sessionConfigured` flag — the session is configured exactly once per process lifetime, regardless of how many engines are created. Each engine instance still registers its own `interruptionNotification` and `routeChangeNotification` observers independently. The static flag is reset in `detachFromEngine(for:)` so a hot restart correctly reconfigures the session for the next engine lifecycle.

## 0.0.5

### Bug fixes

* **`clearAll` unhandled exception on startup.** On every cold start and hot restart the Dart constructor called `clearAll` on the native engine map (a fire-and-forget method with no `playerId`). On Android, iOS, and macOS the `playerId` guard ran unconditionally at the top of `onMethodCall` / `handle(_:result:)` and `handleMetronomeCall`, so `clearAll` was rejected with `PlatformException(INVALID_ARGS, 'playerId' is required)` before it could be dispatched. Because the call is fire-and-forget the error surfaced as an unhandled exception: two per launch (one from `LoopAudioPlayer`, one from `MetronomePlayer`). Fixed by handling `clearAll` as an early-return before the `playerId` guard in all three platforms (Android, iOS, macOS). The now-unreachable duplicate `clearAll` cases inside the `when`/`switch` blocks were removed.

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
