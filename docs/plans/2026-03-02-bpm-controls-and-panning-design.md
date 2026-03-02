# BPM Controls + Panning — Design Document
**Date:** 2026-03-02
**Author:** Claude
**Status:** Approved

---

## Goal

Add four user-facing features to `flutter_gapless_loop`:

1. **Manual BPM input** — text field to type an exact BPM
2. **BPM increment / decrement** — `−`/`+` buttons (±1 BPM; long-press repeats)
3. **Tap tempo** — button that derives BPM from tap intervals
4. **Audio panning** — stereo pan control (−1.0 left ↔ 0.0 centre ↔ 1.0 right)

BPM controls (1–3) live entirely in the example app — no native code required.
Panning (4) is a first-class plugin API addition on both iOS and Android.

---

## Feature 1–3: BPM Controls (Example App)

### Manual BPM input

- `_manualBpm` (`double`) state variable, initialised to `0.0`.
- When `bpmStream` fires, `_manualBpm` is populated from `result.bpm` (auto-fill, user can override).
- A `TextField` with `keyboardType: TextInputType.numberWithOptions(decimal: true)` lets the user type any BPM.
- The field shows `_manualBpm.toStringAsFixed(1)`.

### Increment / Decrement

- `−` and `+` `IconButton`s flanking the BPM field.
- Each press adjusts `_manualBpm` by ±1.0, clamped to `[20.0, 300.0]`.
- Long-press uses a repeating `Timer` (initial delay 400 ms, repeat interval 100 ms) for continuous adjustment while held.

### Tap Tempo

- `_tapTimes` (`List<DateTime>`) records the last 8 tap timestamps.
- On each tap: append `DateTime.now()`. If the gap since the last tap exceeds 3 seconds, reset the list first.
- After ≥ 2 taps: compute average interval across consecutive pairs → `bpm = 60.0 / avgIntervalSecs`.
- Result is written to `_manualBpm` (and the text field updates).

### Snap Loop to Beat

- Enabled only when `_manualBpm > 0` and a file is loaded.
- `beatPeriod = 60.0 / _manualBpm`
- `newStart = (loopStart / beatPeriod).round() * beatPeriod`
- `newEnd   = (loopEnd   / beatPeriod).round() * beatPeriod`
- Clamp both to `[0.0, duration]`. If `newStart >= newEnd`, skip.
- Calls `_player.setLoopRegion(newStart, newEnd)` and updates UI state.

### No plugin API changes required for BPM controls.

---

## Feature 4: Panning — Plugin API

### Dart API

**New method on `LoopAudioPlayer`** (`lib/src/loop_audio_player.dart`):

```dart
/// Sets the stereo pan position.
///
/// [pan] must be in [-1.0, 1.0]:
/// - `-1.0` = full left
/// - `0.0`  = centre (default)
/// - `1.0`  = full right
///
/// Takes effect immediately. Persists across loads.
Future<void> setPan(double pan) async {
  _checkNotDisposed();
  await _methodChannel.invokeMethod('setPan', {
    'pan': pan.clamp(-1.0, 1.0),
  });
}
```

### Method Channel

Channel: `"flutter_gapless_loop"` (existing)
New method: `"setPan"` → argument `{"pan": double}`

### iOS — `LoopAudioEngine.swift`

`AVAudioMixerNode` has a built-in `pan` property (Float, −1…1, equal-power curve).
Signal chain: `nodeA → mixerNode → mainMixerNode → outputNode`
The `mixerNode` is already in the graph for all playback modes.

**Changes:**
- Add `public func setPan(_ pan: Float)` that sets `mixerNode.pan = pan` on `audioQueue`.
- No stored property needed — `mixerNode.pan` is the source of truth.
- Persists across loads automatically (graph is not torn down between loads).

**`FlutterGaplessLoopPlugin.swift`:** wire `"setPan"` → `engine.setPan(Float(pan))`.

### Android — `LoopAudioEngine.kt`

`AudioTrack.setStereoVolume(leftGain, rightGain)` applies independent gain to the left and right output channels regardless of source channel count.

**Equal-power formula** (pan ∈ [−1, 1] → angle ∈ [0, π/2]):

```
angle     = (pan + 1.0) * (PI / 4.0)
leftGain  = cos(angle)
rightGain = sin(angle)
```

At centre (pan=0): angle=π/4 → leftGain=rightGain=√2/2 ≈ 0.707
At full left (pan=−1): leftGain=1.0, rightGain=0.0
At full right (pan=+1): leftGain=0.0, rightGain=1.0

**Changes to `LoopAudioEngine.kt`:**
- Add `@Volatile private var panValue: Float = 0f`
- Add `fun setPan(pan: Float)` that stores the value and calls `applyPan()`.
- Add private `applyPan()` that computes gains and calls `audioTrack?.setStereoVolume(leftGain, rightGain)`.
- Call `applyPan()` after every `AudioTrack` creation in `commitDecodedAudio()` so pan persists across loads.

**`FlutterGaplessLoopPlugin.kt`:** wire `"setPan"` → `eng.setPan(pan.toFloat())`.

### Example App UI

New "Panning" section in `example/lib/main.dart`:
- `_pan` (`double`) state, initially `0.0`.
- `Slider` with `min: -1.0`, `max: 1.0`, `divisions: 200`.
- Labels: **L** (left), **C** (centre tick), **R** (right).
- `onChanged`: calls `_player.setPan(value)` and updates `_pan`.
- Disabled when no file loaded.

---

## Threading

| Platform | `setPan` call thread | Notes |
|----------|---------------------|-------|
| iOS | `audioQueue.async` | Same pattern as `setVolume` |
| Android | Any thread safe via `@Volatile` | `setStereoVolume` is thread-safe |

---

## Error Handling

| Condition | Behaviour |
|-----------|-----------|
| `setPan` called before `load` | iOS: `mixerNode.pan` is set but ignored until engine starts. Android: stored and applied at next `AudioTrack` creation. |
| `pan` out of range | Clamped to [−1.0, 1.0] in Dart before channel call. |
| Mono source file | Android: `setStereoVolume` still routes to stereo output correctly. iOS: `mixerNode` handles mono→stereo with pan. |

---

## Files Changed

| File | Change |
|------|--------|
| `lib/src/loop_audio_player.dart` | Add `setPan(double pan)` |
| `ios/Classes/LoopAudioEngine.swift` | Add `setPan(_ pan: Float)` using `mixerNode.pan` |
| `ios/Classes/FlutterGaplessLoopPlugin.swift` | Wire `"setPan"` method |
| `android/src/main/kotlin/.../LoopAudioEngine.kt` | Add `setPan`, `panValue`, `applyPan()` |
| `android/src/main/kotlin/.../FlutterGaplessLoopPlugin.kt` | Wire `"setPan"` method |
| `example/lib/main.dart` | Add BPM controls section + Panning slider |

No new files needed. No test file changes (panning is exercised by build verification; BPM controls are pure UI).
