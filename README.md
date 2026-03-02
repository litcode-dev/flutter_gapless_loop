# flutter_gapless_loop

A Flutter plugin for true sample-accurate gapless audio looping on iOS (AVAudioEngine) and Android (AudioTrack). Zero-gap, zero-click loop playback for music production apps, with BPM detection, pitch-preserving speed control, and stereo panning.

## Features

- Sample-accurate looping with no audible gap or click at the loop boundary
- Configurable loop region (start and end points in seconds)
- Optional crossfade between loop iterations (equal-power)
- Automatic BPM/tempo detection after every load
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
  flutter_gapless_loop: ^0.0.1
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

## Usage

### Loading audio

Load from a Flutter asset (recommended — works in release builds):

```dart
await player.load('assets/loop.wav');
```

Load from an absolute file system path (e.g. from a file picker):

```dart
await player.loadFromFile('/path/to/loop.wav');
```

Both methods decode the file on a background thread. Listen to `stateStream` to know when the file is ready.

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

### Listening to state changes

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

### Listening to errors

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

## API reference

### `LoopAudioPlayer`

| Method / Getter | Description |
|----------------|-------------|
| `load(String assetPath)` | Load from a Flutter asset key (e.g. `'assets/loop.wav'`). |
| `loadFromFile(String filePath)` | Load from an absolute file system path. |
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
| `bpmStream` | `Stream<BpmResult>` — BPM analysis result after each load. |
| `dispose()` | Release all native resources. Instance unusable after this. |

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
| `confidence` | `double` | Confidence in `[0.0, 1.0]`. Values > 0.5 indicate reliable detection. |
| `beats` | `List<double>` | Beat timestamps in seconds from the start of the file. |

### `RouteChangeEvent` / `RouteChangeReason`

| Reason | Description |
|--------|-------------|
| `headphonesUnplugged` | Audio output device (e.g. headphones) was removed. |
| `categoryChange` | AVAudioSession category changed. |
| `unknown` | Other route change reason. |

## Important notes

- **Single instance per app.** This plugin uses a single shared `MethodChannel`. Instantiating multiple `LoopAudioPlayer` objects causes cross-talk. Create one instance and reuse it.
- **Always call `dispose()`** when the player is no longer needed to release native resources.
- All methods throw `PlatformException` if the native engine returns an error (e.g. file not found, unsupported format).
- **Playback rate on Android** uses `PlaybackParams` (API 23+). On devices running Android 5 or 6, `setPlaybackRate` has no effect.
- **Crossfade** must be shorter than half the loop region. Very short loop regions with a long crossfade may behave unexpectedly.

## License

MIT — see [LICENSE](LICENSE).
