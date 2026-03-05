# Metronome Feature — Design

**Date:** 2026-03-05
**Status:** Approved

## Overview

Add a sample-accurate metronome to the plugin as a standalone `MetronomePlayer` class. The metronome runs independently from `LoopAudioPlayer` — both can play simultaneously. The user supplies BPM, time signature numerator, and separate click / accent audio bytes. The native engine pre-generates a single bar of PCM audio and loops it using the hardware scheduler for zero-jitter timing.

## Architecture

### Core concept: generate-and-loop

Rather than a real-time click scheduler, `MetronomeEngine` pre-generates a single-bar PCM buffer:
- Place the **accent** sample at beat position 0
- Place the **click** sample at beat positions 1…(beatsPerBar-1)
- Fill remaining samples with silence

This buffer is scheduled with `.loops` / loop mode on a dedicated audio node. The hardware handles seamless repetition — zero timer jitter, same code path as the existing loop engine.

On `setBpm` or `setBeatsPerBar`, the buffer is regenerated and the node restarted with a brief crossfade to avoid a click artefact.

### Channels

- Method channel: `"flutter_gapless_loop/metronome"`
- Event channel: `"flutter_gapless_loop/metronome/events"`

### Beat tick events

A `Handler`/`DispatchSourceTimer` fires `{ 'type': 'beatTick', 'beat': N }` on the event channel at each beat interval. This is UI-only (±5ms jitter is acceptable for visual feedback). Audio timing is driven by the hardware loop, not the timer.

### Native files

| File | Purpose |
|------|---------|
| `ios/Classes/MetronomeEngine.swift` | New. Bar buffer generation + AVAudioPlayerNode loop + beat tick timer |
| `android/src/.../MetronomeEngine.kt` | New. Bar buffer generation + AudioTrack loop + Handler beat timer |
| `ios/Classes/FlutterGaplessLoopPlugin.swift` | Register new method + event channels, wire MetronomeEngine |
| `android/src/.../FlutterGaplessLoopPlugin.kt` | Register new method + event channels, wire MetronomeEngine |

### Dart files

| File | Purpose |
|------|---------|
| `lib/src/metronome_player.dart` | New. `MetronomePlayer` class |
| `lib/flutter_gapless_loop.dart` | Export `metronome_player.dart` |
| `test/metronome_player_test.dart` | New. Unit tests |

## API

```dart
class MetronomePlayer {
  /// Method channel: "flutter_gapless_loop/metronome"
  /// Event channel:  "flutter_gapless_loop/metronome/events"

  /// Starts the metronome.
  ///
  /// [bpm]         — tempo in beats per minute. Must be in (0, 400].
  /// [beatsPerBar] — time signature numerator. Must be in [1, 16].
  /// [click]       — audio bytes for a regular beat (WAV/PCM).
  /// [accent]      — audio bytes for the downbeat (beat 0 of each bar).
  /// [extension]   — decoder hint for click/accent format, default 'wav'.
  Future<void> start({
    required double bpm,
    required int beatsPerBar,
    required Uint8List click,
    required Uint8List accent,
    String extension = 'wav',
  }) async

  /// Stops the metronome immediately.
  Future<void> stop() async

  /// Updates tempo without stopping. Regenerates bar buffer.
  Future<void> setBpm(double bpm) async

  /// Updates time signature. Regenerates bar buffer.
  Future<void> setBeatsPerBar(int beatsPerBar) async

  /// Beat index fired on each click: 0 = downbeat, 1…N-1 = regular beats.
  /// UI hint only — not used for audio scheduling.
  Stream<int> get beatStream

  /// Releases all native resources.
  Future<void> dispose() async
}
```

## Method Channel Payloads

| Method | Arguments |
|--------|-----------|
| `start` | `{ 'bpm': double, 'beatsPerBar': int, 'click': Uint8List, 'accent': Uint8List, 'extension': String }` |
| `stop` | — |
| `setBpm` | `{ 'bpm': double }` |
| `setBeatsPerBar` | `{ 'beatsPerBar': int }` |
| `dispose` | — |

Event: `{ 'type': 'beatTick', 'beat': int }` — beat index 0-indexed within bar.

## Error Handling

| Scenario | Behaviour |
|----------|-----------|
| `bpm ≤ 0` or `bpm > 400` | `ArgumentError` thrown in Dart before channel call |
| `beatsPerBar < 1` or `> 16` | `ArgumentError` thrown in Dart |
| Click/accent bytes fail decode | Native fires `{ 'type': 'error', 'message': '...' }` on event channel |
| `setBpm`/`setBeatsPerBar` before `start` | No-op |
| Called after `dispose` | `StateError` |

## Testing

**Dart unit tests (`test/metronome_player_test.dart`):**
- `start` sends correct method channel payload
- `ArgumentError` for bpm ≤ 0, bpm > 400
- `ArgumentError` for beatsPerBar < 1, beatsPerBar > 16
- `beatStream` correctly parses `beatTick` events
- `StateError` after dispose

**Example app:** Add `_MetronomeCard` widget with start/stop button, BPM stepper (reuses existing ±1 pattern), time signature dropdown (2–7), beat indicator dots that flash on `beatStream`.

## Non-goals

- Volume control for metronome clicks (out of scope)
- Swing/groove quantisation (out of scope)
- Sub-beat subdivisions (out of scope)
- Sync to `LoopAudioPlayer` playback position (out of scope)
