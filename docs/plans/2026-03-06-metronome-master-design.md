# MetronomeMaster — Design Document

**Date:** 2026-03-06
**Status:** Approved

## Goal

Add a `MetronomeMaster` static class that acts as a multiplicative group-bus fader over all live `MetronomePlayer` instances. Each instance keeps its own relative volume and pan; the master scales/shifts them without changing the per-instance values.

- `effectiveVolume = (localVolume × masterVolume).clamp(0.0, 1.0)`
- `effectivePan    = (localPan + masterPan).clamp(−1.0, 1.0)`

Dart handles all computation. Native engines receive only the final effective float.

---

## Architecture

### Layer 1 — Native `MetronomeEngine`

Add `setVolume(Float)` and `setPan(Float)` to both platform engines.

**iOS (`MetronomeEngine.swift`):**
- Volume: `audioEngine.mainMixerNode.volume = volume`
- Pan:    `audioEngine.mainMixerNode.pan = pan`
- `setupAndPlay` recreates `AVAudioEngine` on every BPM/time-sig change, so store `private var _volume: Float = 1.0` and `private var _pan: Float = 0.0` and re-apply them after each rebuild inside `setupAndPlay`.

**Android (`MetronomeEngine.kt`):**
- Volume: `audioTrack?.setVolume(volume)`
- Pan:    `val (l, r) = panToGains(pan); audioTrack?.setStereoVolume(l, r)` — reuses the existing top-level `panToGains` helper.
- Store `private var _volume: Float = 1.0` and `private var _pan: Float = 0.0`, re-apply at end of `buildAudioTrack()`.

### Layer 2 — Plugin bridges

Add `setVolume` and `setPan` cases to `handleMetronomeCall` on both platforms. Args: `{playerId, volume/pan: double}`. Routes to correct engine in registry by `playerId`.

### Layer 3 — Dart

**`MetronomePlayer` additions** (in `lib/src/metronome_player.dart`):

```dart
double _localVolume = 1.0;
double _localPan    = 0.0;

Future<void> setVolume(double volume) async {
  _checkNotDisposed();
  _localVolume = volume.clamp(0.0, 1.0);
  await _channel.invokeMethod('setVolume', {
    'playerId': _playerId,
    'volume': (_localVolume * MetronomeMaster._masterVolume).clamp(0.0, 1.0),
  });
}

Future<void> setPan(double pan) async {
  _checkNotDisposed();
  _localPan = pan.clamp(-1.0, 1.0);
  await _channel.invokeMethod('setPan', {
    'playerId': _playerId,
    'pan': (_localPan + MetronomeMaster._masterPan).clamp(-1.0, 1.0),
  });
}
```

**`MetronomeMaster`** (new static class, same file as `MetronomePlayer`):

```dart
class MetronomeMaster {
  MetronomeMaster._();

  static final Set<MetronomePlayer> _instances = {};
  static double _masterVolume = 1.0;
  static double _masterPan    = 0.0;

  static double get volume => _masterVolume;
  static double get pan    => _masterPan;

  static Future<void> setVolume(double volume) async {
    _masterVolume = volume.clamp(0.0, 1.0);
    for (final inst in _instances) {
      if (!inst._isDisposed) await inst._applyEffectiveVolume();
    }
  }

  static Future<void> setPan(double pan) async {
    _masterPan = pan.clamp(-1.0, 1.0);
    for (final inst in _instances) {
      if (!inst._isDisposed) await inst._applyEffectivePan();
    }
  }

  static Future<void> reset() async {
    _masterVolume = 1.0;
    _masterPan    = 0.0;
    for (final inst in _instances) {
      if (!inst._isDisposed) {
        await inst._applyEffectiveVolume();
        await inst._applyEffectivePan();
      }
    }
  }
}
```

`MetronomePlayer` registers in constructor (`MetronomeMaster._instances.add(this)`) and unregisters in `dispose()` (`MetronomeMaster._instances.remove(this)`).

`setVolume`/`setPan` on each instance delegate to private `_applyEffectiveVolume`/`_applyEffectivePan` helpers so the effective-value computation is not duplicated.

---

## API Surface

### `MetronomePlayer` (additions)

| Method | Args | Notes |
|--------|------|-------|
| `setVolume(double)` | 0.0–1.0, clamped | Stores local, sends effective |
| `setPan(double)` | −1.0–1.0, clamped | Stores local, sends effective |

### `MetronomeMaster` (new)

| Member | Type | Notes |
|--------|------|-------|
| `volume` | `double` getter | Current master volume (default 1.0) |
| `pan` | `double` getter | Current master pan (default 0.0) |
| `setVolume(double)` | `Future<void>` | Stores master, re-applies to all instances |
| `setPan(double)` | `Future<void>` | Stores master, re-applies to all instances |
| `reset()` | `Future<void>` | Restores 1.0 / 0.0, re-applies |

### New native method channel calls (metronome channel)

| Method | Args | Description |
|--------|------|-------------|
| `setVolume` | `{playerId, volume: double}` | Effective volume, pre-multiplied |
| `setPan` | `{playerId, pan: double}` | Effective pan, pre-clamped |

---

## Error Handling

- All clamping is Dart-side; no validation errors thrown — values outside range are silently clamped.
- `_isDisposed` guard prevents master propagation from calling into disposed instances.
- `StateError` thrown by `_checkNotDisposed()` if `setVolume`/`setPan` called after dispose (consistent with existing API).

---

## Testing

**New file:** `test/metronome_master_test.dart`

| Test | Verifies |
|------|----------|
| `setVolume` sends `localVolume × masterVolume` to native | Dart multiplication |
| `setPan` sends `clamp(localPan + masterPan)` to native | Dart additive offset |
| Two instances both re-notified when master `setVolume` changes | Registry iteration |
| Two instances both re-notified when master `setPan` changes | Registry iteration |
| Disposed instance is skipped during master propagation | `_isDisposed` guard |
| `reset()` restores defaults and re-applies to all instances | Reset behaviour |
| Volume clamped to 1.0 when > 1.0 | Validation |
| Pan clamped to ±1.0 when out of range | Validation |

**Existing tests:** no changes required — `setVolume`/`setPan` are new methods.

**iOS/Android:** no new unit tests — native methods are thin wrappers over platform APIs; all logic is in Dart.

**Build verification:** `flutter build ios --no-codesign` after iOS native changes.

---

## Files Changed

| File | Change |
|------|--------|
| `lib/src/metronome_player.dart` | Add `setVolume`, `setPan`, `_localVolume`, `_localPan`, registration; add `MetronomeMaster` class |
| `lib/flutter_gapless_loop.dart` | Export `MetronomeMaster` |
| `ios/Classes/MetronomeEngine.swift` | Add `setVolume`, `setPan`, `_volume`, `_pan` fields, re-apply in `setupAndPlay` |
| `ios/Classes/FlutterGaplessLoopPlugin.swift` | Add `setVolume`/`setPan` cases in `handleMetronomeCall` |
| `android/.../MetronomeEngine.kt` | Add `setVolume`, `setPan`, `_volume`, `_pan` fields, re-apply in `buildAudioTrack` |
| `android/.../FlutterGaplessLoopPlugin.kt` | Add `setVolume`/`setPan` cases in `handleMetronomeCall` |
| `test/metronome_master_test.dart` | New — 8 unit tests |
