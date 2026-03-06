
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
