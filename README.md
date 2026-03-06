# flutter_gapless_loop

A Flutter plugin for true sample-accurate gapless audio looping on iOS (AVAudioEngine) and Android (AudioTrack). Zero-gap, zero-click loop playback for music production apps, with BPM and time signature detection, a built-in sample-accurate metronome, pitch-preserving speed control, and stereo panning.

## Features

- Sample-accurate looping with no audible gap or click at the loop boundary
- Configurable loop region (start and end points in seconds)
- Optional crossfade between loop iterations (equal-power)
- Automatic BPM/tempo detection after every load
- Automatic time signature detection (beats per bar + bar timestamps)
- Load audio from an asset, a file path, raw bytes, or a URL
- Built-in `MetronomePlayer` — sample-accurate click track with accent, runs simultaneously with the loop player
- Pitch-preserving playback rate control (time-stretching)
- Stereo pan control
- Volume control
- Seek support
- State and error streams for reactive UI
- Audio route change events (e.g. headphones unplugged)

## Platform support

| Platform | Support | Engine |
|----------|---------|--------|
| iOS      | ✅      | AVAudioEngine + AVAudioUnitTimePitch |
| Android  | ✅      | AudioTrack (API 21+) |

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  flutter_gapless_loop: ^0.0.2
```

Then run:

```sh
flutter pub get
```

## Quick start

```dart
import 'package:flutter_gapless_loop/flutter_gapless_loop.dart';

final player = LoopAudioPlayer();

// Load and play
await player.load('assets/loop.wav');
await player.play();

// Dispose when done
await player.dispose();
```

---

## Multiple instances

You can create any number of `LoopAudioPlayer` or `MetronomePlayer` instances and run them concurrently — each is fully independent with no cross-talk:

```dart
final bass   = LoopAudioPlayer();
final drums  = LoopAudioPlayer();
final metro1 = MetronomePlayer();
final metro2 = MetronomePlayer();

await bass.loadFromFile('/path/to/bass.wav');
await drums.loadFromFile('/path/to/drums.wav');
await bass.play();
await drums.play();

await metro1.start(bpm: 120, beatsPerBar: 4, click: click, accent: accent);
await metro2.start(bpm: 90,  beatsPerBar: 3, click: click, accent: accent);

// Each player's event streams are isolated
bass.stateStream.listen((s)  => print('bass: $s'));
drums.bpmStream.listen((r)   => print('drums bpm: ${r.bpm}'));
metro1.beatStream.listen((b) => print('metro1 beat: $b'));
metro2.beatStream.listen((b) => print('metro2 beat: $b'));

// Independent lifecycle — disposing one does not affect the others
await bass.dispose();
await metro1.dispose();
```

---

## LoopAudioPlayer

### Loading audio

**From a Flutter asset** (recommended — works in release builds):

```dart
await player.load('assets/loop.wav');
```

**From an absolute file system path** (e.g. from a file picker):

```dart
await player.loadFromFile('/path/to/loop.wav');
```

**From raw bytes** (e.g. downloaded or generated in memory):

```dart
final Uint8List bytes = await someSource.fetchBytes();
await player.loadFromBytes(bytes);                         // defaults to .wav
await player.loadFromBytes(bytes, extension: 'mp3');       // explicit format hint
```

**From a URL** (downloaded natively, then loaded):

```dart
await player.loadFromUrl(Uri.parse('https://example.com/loop.wav'));
```

The download uses the platform networking stack — `URLSession` on iOS and `HttpURLConnection` on Android. No third-party HTTP package is required.

All four methods decode on a background thread. Subscribe to `stateStream` to know when the file is ready.

### Playback control

```dart
await player.play();    // start looping from the beginning
await player.pause();   // pause (preserves position)
await player.resume();  // resume from the paused position
await player.stop();    // stop and reset position
```

### Volume

```dart
await player.setVolume(0.8); // 0.0 (silent) → 1.0 (full volume)
```

Throws `ArgumentError` if the value is outside `[0.0, 1.0]`.

### Stereo pan

```dart
await player.setPan(-1.0); // full left
await player.setPan(0.0);  // centre (default)
await player.setPan(1.0);  // full right
```

Values outside `[-1.0, 1.0]` are silently clamped. Takes effect immediately and persists across loads.

### Playback rate (pitch-preserving speed)

```dart
await player.setPlaybackRate(1.0);  // normal speed (default)
await player.setPlaybackRate(2.0);  // double speed
await player.setPlaybackRate(0.5);  // half speed
```

- Uses `AVAudioUnitTimePitch` on iOS and `PlaybackParams.setSpeed` on Android (API 23+; no-op on older devices).
- Values outside `[0.25, 4.0]` are clamped.
- Takes effect immediately and persists across loads.

### Loop region

Restrict looping to a sub-section of the file:

```dart
await player.setLoopRegion(1.5, 8.0); // loop between 1.5s and 8.0s
await player.play();
```

Both `start` and `end` are in seconds. `start` must be `>= 0` and `end` must be greater than `start`.

Call `setLoopRegion` before or after `play()`. Clear by loading a new file.

### Crossfade

Add a smooth crossfade at the loop boundary:

```dart
await player.setCrossfadeDuration(0.3); // 300 ms equal-power crossfade
await player.play();
```

Set to `0.0` (default) to disable crossfade and use the lowest-latency loop path. The crossfade duration must be less than half the loop region length.

### Seek

```dart
await player.seek(3.5); // seek to 3.5 seconds
```

Seeking while playing triggers a brief reschedule on the native side. The next loop boundary will restart from the loop region start, not the seek position.

### Duration and position

```dart
final duration = await player.duration;         // returns Duration
final position = await player.currentPosition;  // returns double (seconds)
```

`duration` returns `Duration.zero` if no file is loaded. `currentPosition` returns `0.0` if not playing.

### State stream

```dart
player.stateStream.listen((PlayerState state) {
  switch (state) {
    case PlayerState.loading: print('Loading…');
    case PlayerState.ready:   print('Ready');
    case PlayerState.playing: print('Playing');
    case PlayerState.paused:  print('Paused');
    case PlayerState.stopped: print('Stopped');
    case PlayerState.error:   print('Error — check errorStream');
    case PlayerState.idle:    print('Idle');
  }
});
```

### Error stream

```dart
player.errorStream.listen((String message) {
  print('Error: $message');
});
```

Errors also set `stateStream` to `PlayerState.error`.

### Audio route changes

Pause automatically when headphones are unplugged:

```dart
player.routeChangeStream.listen((RouteChangeEvent event) {
  if (event.reason == RouteChangeReason.headphonesUnplugged) {
    player.pause();
  }
});
```

### BPM detection

After every successful load, the plugin analyses the audio on a background thread and emits a `BpmResult` on `bpmStream`. This fires once per load, shortly after `stateStream` emits `PlayerState.ready`.

```dart
player.bpmStream.listen((BpmResult result) {
  print('BPM: ${result.bpm.toStringAsFixed(1)}');
  print('Confidence: ${result.confidence.toStringAsFixed(2)}');
  print('Beat timestamps: ${result.beats}');
});
```

`bpm` is `0.0` if the audio is shorter than 2 seconds or completely silent.

**Using detected BPM to drive playback rate:**

```dart
double detectedBpm = 0;
double targetBpm   = 0;

player.bpmStream.listen((r) {
  detectedBpm = r.bpm;
  targetBpm   = r.bpm; // initialise to detected value
});

// When the user changes the target BPM:
void setTargetBpm(double bpm) {
  targetBpm = bpm;
  if (detectedBpm > 0) {
    player.setPlaybackRate(targetBpm / detectedBpm);
  }
}
```

### Time signature detection

`BpmResult` also includes the detected time signature. This is emitted on the same `bpmStream` call, at no extra cost.

```dart
player.bpmStream.listen((BpmResult result) {
  if (result.bpm == 0) return; // detection skipped

  print('${result.bpm.toStringAsFixed(1)} BPM');

  if (result.beatsPerBar > 0) {
    print('Time signature: ${result.beatsPerBar}/4');
    print('Bar count: ${result.bars.length}');
    print('Bar timestamps (s): ${result.bars}');
  }
});
```

`beatsPerBar` is `0` when confidence is too low (< 0.3) to make a reliable meter estimate. The detector evaluates candidates `{2, 3, 4, 6, 7}` with a Gaussian prior favouring 4/4.

**Using detected time signature to pre-configure the metronome:**

```dart
player.bpmStream.listen((BpmResult r) async {
  if (r.bpm > 0 && r.beatsPerBar > 0) {
    await metronome.start(
      bpm: r.bpm,
      beatsPerBar: r.beatsPerBar,
      click: clickBytes,
      accent: accentBytes,
    );
  }
});
```

---

## MetronomePlayer

`MetronomePlayer` runs a sample-accurate click track independently from `LoopAudioPlayer`. Both can play at the same time. The metronome pre-generates a single-bar PCM buffer (accent on beat 0, click on beats 1…N-1) and loops it via the hardware scheduler.

You supply the click and accent sounds as raw audio bytes (`Uint8List`). Any format supported by the platform decoder is accepted (WAV, MP3, AAC, FLAC, etc.).

### Basic usage

```dart
import 'package:flutter_gapless_loop/flutter_gapless_loop.dart';

final metronome = MetronomePlayer();

// Load your click/accent audio bytes (e.g. from assets or generated)
final clickBytes  = (await rootBundle.load('assets/click.wav')).buffer.asUint8List();
final accentBytes = (await rootBundle.load('assets/accent.wav')).buffer.asUint8List();

// Start at 120 BPM in 4/4
await metronome.start(
  bpm: 120.0,
  beatsPerBar: 4,
  click: clickBytes,
  accent: accentBytes,
);

// Stop
await metronome.stop();

// Dispose when done
await metronome.dispose();
```

### Beat stream

Subscribe to `beatStream` to animate a UI beat indicator. The stream emits the current beat index on each tick: `0` = downbeat (accent), `1`…`N-1` = regular beats. This is a UI hint only — it is not used for audio scheduling and has ±5 ms jitter.

```dart
metronome.beatStream.listen((int beat) {
  setState(() => _currentBeat = beat);
});
```

### Changing tempo or time signature without stopping

```dart
await metronome.setBpm(140.0);       // new tempo — bar buffer is regenerated
await metronome.setBeatsPerBar(3);   // change to 3/4 — bar buffer is regenerated
```

Both methods are no-ops if the metronome has not been started yet. The bar buffer is rebuilt immediately and playback resumes from beat 0.

### Time signatures

`beatsPerBar` accepts any value in `[1, 16]`. You can use it to represent simple and compound meters:

| Meter | `beatsPerBar` | `bpm` interpretation |
|-------|-------------|----------------------|
| 4/4   | `4`         | quarter note = BPM   |
| 3/4   | `3`         | quarter note = BPM   |
| 2/4   | `2`         | quarter note = BPM   |
| 6/8   | `6`         | eighth note = BPM    |
| 5/8   | `5`         | eighth note = BPM    |
| 7/8   | `7`         | eighth note = BPM    |
| 12/8  | `12`        | eighth note = BPM    |

> **Note on compound meter:** The current API places an accent only on beat 0. In 6/8 the conventional accent falls on both beat 0 and beat 3. If you need per-beat accent patterns, use two separate `MetronomePlayer` instances — one with `beatsPerBar: 2` (dotted-quarter pulse) for the accents and one with `beatsPerBar: 6` for the subdivisions — or generate a custom bar buffer and use `loadFromBytes`.

**Example — 6/8 at dotted-quarter = 80 BPM:**

```dart
// BPM is expressed as the eighth-note pulse rate
await metronome.start(
  bpm: 240,        // 80 dotted-quarter × 3 eighth-notes = 240 eighth-notes per minute
  beatsPerBar: 6,
  click: clickBytes,
  accent: accentBytes,
);
```

### Validation

| Parameter | Valid range | Exception |
|-----------|------------|-----------|
| `bpm` | `(0, 400]` | `ArgumentError` |
| `beatsPerBar` | `[1, 16]` | `ArgumentError` |

All methods throw `StateError` if called after `dispose()`.

---

## API reference

### `LoopAudioPlayer`

| Method / Getter | Description |
|----------------|-------------|
| `load(String assetPath)` | Load from a Flutter asset key (e.g. `'assets/loop.wav'`). |
| `loadFromFile(String filePath)` | Load from an absolute file system path. |
| `loadFromBytes(Uint8List bytes, {String extension})` | Load from raw audio bytes. `extension` defaults to `'wav'`. |
| `loadFromUrl(Uri uri)` | Download from an `http`/`https` URL natively and load. Throws `PlatformException` on non-2xx response or decode failure. |
| `play()` | Start looping playback. |
| `pause()` | Pause; preserves position. |
| `resume()` | Resume from paused position. |
| `stop()` | Stop and reset position. |
| `setLoopRegion(double start, double end)` | Loop only the region between `start` and `end` (seconds). |
| `setCrossfadeDuration(double seconds)` | Crossfade duration at loop boundary. `0.0` = disabled. |
| `setVolume(double volume)` | Volume in `[0.0, 1.0]`. |
| `setPan(double pan)` | Stereo pan in `[-1.0, 1.0]`. Values clamped. |
| `setPlaybackRate(double rate)` | Speed multiplier in `[0.25, 4.0]`, pitch-preserving. |
| `seek(double seconds)` | Seek to position in seconds. |
| `duration` | `Future<Duration>` — total length of loaded file. |
| `currentPosition` | `Future<double>` — current playback position in seconds. |
| `stateStream` | `Stream<PlayerState>` — state changes from native layer. |
| `errorStream` | `Stream<String>` — error messages from native layer. |
| `routeChangeStream` | `Stream<RouteChangeEvent>` — audio route changes. |
| `bpmStream` | `Stream<BpmResult>` — BPM + time signature analysis result after each load. |
| `dispose()` | Release all native resources. Instance unusable after this. |

### `MetronomePlayer`

| Method / Getter | Description |
|----------------|-------------|
| `start({required double bpm, required int beatsPerBar, required Uint8List click, required Uint8List accent, String extension})` | Decode click/accent bytes, generate bar buffer, and start looping. `extension` defaults to `'wav'`. |
| `stop()` | Stop the metronome immediately. |
| `setBpm(double bpm)` | Update tempo; regenerates bar buffer. No-op if not started. |
| `setBeatsPerBar(int beatsPerBar)` | Update time signature; regenerates bar buffer. No-op if not started. |
| `setVolume(double volume)` | Instance volume in `[0.0, 1.0]`. Effective volume = `localVolume × MetronomeMaster.volume`. |
| `setPan(double pan)` | Instance pan in `[-1.0, 1.0]`. Effective pan = `clamp(localPan + MetronomeMaster.pan, -1, 1)`. |
| `beatStream` | `Stream<int>` — beat index (0 = downbeat, 1…N-1 = click). UI hint; ±5 ms jitter. |
| `dispose()` | Release all native resources. Instance unusable after this. |

### `MetronomeMaster`

`MetronomeMaster` is a static class that applies master volume and pan across all live `MetronomePlayer` instances. Per-instance relative levels are preserved.

```dart
await MetronomeMaster.setVolume(0.5); // all instances scaled by 0.5
await MetronomeMaster.setPan(0.2);    // all instances shifted right by 0.2
await MetronomeMaster.reset();        // restore volume=1.0, pan=0.0
```

| Member | Description |
|--------|-------------|
| `volume` | Current master volume getter (default `1.0`) |
| `pan` | Current master pan getter (default `0.0`) |
| `setVolume(double volume)` | Scales all live instances: `effectiveVolume = localVolume × masterVolume` |
| `setPan(double pan)` | Shifts all live instances: `effectivePan = clamp(localPan + masterPan, -1, 1)` |
| `reset()` | Restores `volume=1.0` / `pan=0.0` and re-applies to all instances |

### `PlayerState`

| Value | Description |
|-------|-------------|
| `idle` | No file loaded. Initial state. |
| `loading` | File is being read and decoded. |
| `ready` | File loaded; engine ready to play. |
| `playing` | Audio is actively looping. |
| `paused` | Paused; can resume without reloading. |
| `stopped` | Stopped; position reset. |
| `error` | Unrecoverable error; check `errorStream`. |

### `BpmResult`

| Field | Type | Description |
|-------|------|-------------|
| `bpm` | `double` | Estimated tempo in BPM. `0.0` if detection was skipped. |
| `confidence` | `double` | Detection confidence in `[0.0, 1.0]`. Values above `0.5` are reliable. |
| `beats` | `List<double>` | Beat timestamps in seconds from the start of the file. |
| `beatsPerBar` | `int` | Detected beats per bar (time signature numerator). `0` if confidence < 0.3. |
| `bars` | `List<double>` | Bar start timestamps in seconds. Empty if `beatsPerBar` is `0`. |

### `RouteChangeEvent` / `RouteChangeReason`

| Reason | Description |
|--------|-------------|
| `headphonesUnplugged` | Audio output device (e.g. headphones) was removed. |
| `categoryChange` | AVAudioSession category changed (iOS only). |
| `unknown` | Other route change reason. |

---

## Implementation notes

### Native engines

| Feature | iOS | Android |
|---------|-----|---------|
| Loop player | `AVAudioPlayerNode.scheduleBuffer(.loops)` | `AudioTrack MODE_STREAM` |
| Metronome | `AVAudioPlayerNode.scheduleBuffer(.loops)` on dedicated engine | `AudioTrack MODE_STATIC` + `setLoopPoints` |
| URL loading | `URLSession.shared.dataTask` | `HttpURLConnection` on `Dispatchers.IO` |
| Time pitch | `AVAudioUnitTimePitch` | `PlaybackParams.setSpeed` (API 23+) |
| BPM detection | `DispatchWorkItem` on `.utility` queue | `Dispatchers.Default` coroutine |
| Pan | `AVAudioMixerNode.pan` | Equal-power formula → `setStereoVolume` |

### Click prevention

A 5 ms linear micro-fade is applied to both ends of every loop buffer at load time. This eliminates audible clicks at the loop boundary and at metronome restarts with zero runtime cost.

### Threading

- **iOS:** All engine state mutations run on a dedicated serial `audioQueue` (`DispatchQueue`, `.userInteractive`). Flutter method results and event sink calls are dispatched back to `DispatchQueue.main`.
- **Android:** Coroutine scope uses `Dispatchers.Main + SupervisorJob()`. IO-bound work (file decode) suspends on `Dispatchers.IO`. All `EventChannel.EventSink` calls are posted through a `Handler(Looper.getMainLooper())`.

---

## Important notes

- **Multiple instances are supported.** You can create any number of `LoopAudioPlayer` or `MetronomePlayer` instances and they will run concurrently without cross-talk. Each instance is independently tracked by the native layer via a unique player ID.
- **`LoopAudioPlayer` and `MetronomePlayer` are independent.** They use separate method and event channels and can run simultaneously without interfering with each other.
- **Always call `dispose()`** when a player is no longer needed to release native resources.
- All methods throw `PlatformException` if the native engine returns an error (e.g. file not found, unsupported format).
- **Playback rate on Android** uses `PlaybackParams` (API 23+). On devices running Android 5 or 6, `setPlaybackRate` has no effect.
- **Crossfade** must be shorter than half the loop region. Very short loop regions with a long crossfade may behave unexpectedly.
- **Minimum iOS version:** 14.0 (required by `os.log.Logger`).
- **`loadFromUrl`** uses the platform networking stack (`URLSession` on iOS, `HttpURLConnection` on Android). No additional packages are required.

## License

MIT — see [LICENSE](LICENSE).
