# flutter_gapless_loop

A Flutter plugin for true sample-accurate gapless audio looping on iOS (AVAudioEngine) and Android (AudioTrack). Zero-gap, zero-click loop playback for music production apps.

## Features

- Sample-accurate looping with no audible gap or click at the loop boundary
- Configurable loop region (start and end points in seconds)
- Optional crossfade between loop iterations (0–500 ms)
- Volume control
- Seek support
- `stateStream`, `errorStream`, and `routeChangeStream` for reactive UI
- Audio route change events (e.g. headphones unplugged)

## Platform support

| Platform | Support |
|----------|---------|
| iOS      | ✅ (AVAudioEngine) |
| Android  | ✅ (AudioTrack) |

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

## Usage

### Basic playback

```dart
import 'package:flutter_gapless_loop/flutter_gapless_loop.dart';

final player = LoopAudioPlayer();

// Load from a Flutter asset
await player.load('assets/loop.wav');

// Or load from an absolute file path
await player.loadFromFile('/path/to/loop.wav');

// Start looping
await player.play();

// Pause and resume
await player.pause();
await player.resume();

// Stop (resets playback position)
await player.stop();

// Release native resources when done
await player.dispose();
```

Supported formats: WAV, AIFF, MP3, M4A.

### Loop region

Restrict looping to a portion of the file (values in seconds):

```dart
await player.setLoopRegion(1.5, 8.0); // loop between 1.5s and 8.0s
await player.play();
```

### Crossfade

Add a crossfade between loop iterations (0.0–0.5 seconds):

```dart
await player.setCrossfadeDuration(0.3); // 300 ms crossfade
await player.play();
```

Set to `0.0` (the default) to disable crossfade and use the lowest-latency loop path.

### Volume

```dart
await player.setVolume(0.8); // 0.0 (silent) to 1.0 (full volume)
```

### Seek

```dart
await player.seek(3.5); // seek to 3.5 seconds
```

> **Note:** Seeking while the player is in loop mode causes a brief reschedule on the native side. The next loop boundary will restart from the loop region start, not the seek position.

### Duration and position

```dart
final Duration duration = await player.duration;
final double positionSecs = await player.currentPosition; // seconds
```

### Listening to state changes

```dart
player.stateStream.listen((PlayerState state) {
  print('Player state: $state');
});
```

`PlayerState` values: `idle`, `loading`, `ready`, `playing`, `paused`, `stopped`, `error`.

### Listening to errors

```dart
player.errorStream.listen((String message) {
  print('Error: $message');
});
```

### Audio route changes

```dart
player.routeChangeStream.listen((RouteChangeEvent event) {
  if (event.reason == RouteChangeReason.headphonesUnplugged) {
    player.pause();
  }
});
```

`RouteChangeReason` values: `headphonesUnplugged`, `categoryChange`, `unknown`.

## Important notes

- Use a **single `LoopAudioPlayer` instance** per application. Multiple instances share the same native channel and will interfere with each other.
- Always call `dispose()` when the player is no longer needed to release native resources. The instance cannot be used after `dispose()`.
- All methods throw `PlatformException` if the native engine returns an error, and `StateError` if called after `dispose()`.

## License

MIT — see [LICENSE](LICENSE).
