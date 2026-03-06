# LoopAudioMaster — Design Document

**Date:** 2026-03-06
**Status:** Approved

## Goal

Add a `LoopAudioMaster` static class that acts as a multiplicative group-bus fader over all live `LoopAudioPlayer` instances. Each instance keeps its own relative volume and pan; the master scales/shifts them without changing the per-instance values.

- `effectiveVolume = (localVolume × masterVolume).clamp(0.0, 1.0)`
- `effectivePan    = (localPan + masterPan).clamp(−1.0, 1.0)`

Dart handles all computation. Native engines receive only the final effective float.

---

## Architecture

Pure Dart layer — no native changes required.

### `LoopAudioPlayer` modifications

Add `_localVolume = 1.0` and `_localPan = 0.0` fields.

Register in constructor: `LoopAudioMaster._instances.add(this)`.
Unregister in `dispose()`: `LoopAudioMaster._instances.remove(this)`.

Modify `setVolume` and `setPan` to store the local value and delegate to private helpers:

```dart
double _localVolume = 1.0;
double _localPan    = 0.0;

Future<void> setVolume(double volume) async {
  _checkNotDisposed();
  _localVolume = volume.clamp(0.0, 1.0);
  await _applyEffectiveVolume();
}

Future<void> setPan(double pan) async {
  _checkNotDisposed();
  _localPan = pan.clamp(-1.0, 1.0);
  await _applyEffectivePan();
}

Future<void> _applyEffectiveVolume() async {
  final effective = (_localVolume * LoopAudioMaster._masterVolume).clamp(0.0, 1.0);
  await _channel.invokeMethod<void>(
      'setVolume', {'playerId': _playerId, 'volume': effective});
}

Future<void> _applyEffectivePan() async {
  final effective = (_localPan + LoopAudioMaster._masterPan).clamp(-1.0, 1.0);
  await _channel.invokeMethod<void>(
      'setPan', {'playerId': _playerId, 'pan': effective});
}
```

**Behaviour change:** `setVolume` currently throws `ArgumentError` for values outside `[0, 1]`. The new design silently clamps, consistent with `MetronomeMaster` and the existing `setPan` behaviour.

### `LoopAudioMaster` class

New static class added at the bottom of `lib/src/loop_audio_player.dart` (same library as `LoopAudioPlayer`, so it can access private members).

```dart
class LoopAudioMaster {
  LoopAudioMaster._();

  static final Set<LoopAudioPlayer> _instances = {};
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

  @visibleForTesting
  static void resetForTesting() {
    _masterVolume = 1.0;
    _masterPan    = 0.0;
    _instances.clear();
  }
}
```

---

## API Surface

### `LoopAudioPlayer` (modified)

| Method | Change |
|--------|--------|
| `setVolume(double)` | Stores `_localVolume`, sends `localVolume × masterVolume`. Silently clamps instead of throwing. |
| `setPan(double)` | Stores `_localPan`, sends `clamp(localPan + masterPan, −1, 1)`. |

### `LoopAudioMaster` (new)

| Member | Type | Notes |
|--------|------|-------|
| `volume` | `double` getter | Current master volume (default `1.0`) |
| `pan` | `double` getter | Current master pan (default `0.0`) |
| `setVolume(double)` | `Future<void>` | Scales all live instances: `effectiveVolume = localVolume × masterVolume` |
| `setPan(double)` | `Future<void>` | Shifts all live instances: `effectivePan = clamp(localPan + masterPan, −1, 1)` |
| `reset()` | `Future<void>` | Restores `1.0` / `0.0`, re-applies to all instances |

---

## Error Handling

- All clamping Dart-side; no validation errors thrown — values outside range silently clamped.
- `_isDisposed` guard prevents master propagation calling into disposed instances.
- `StateError` thrown by `_checkNotDisposed()` if `setVolume`/`setPan` called after dispose.

---

## Testing

**New file:** `test/loop_audio_master_test.dart`

| Test | Verifies |
|------|----------|
| `setVolume` sends `localVolume × masterVolume` (default 1.0) | Multiplication with identity |
| `setVolume` multiplies by master when master ≠ 1.0 | Dart multiplication |
| `setVolume` clamps effective volume to 1.0 | Upper clamp |
| `setPan` sends `localPan + masterPan` (default 0.0) | Addition with identity |
| `setPan` adds master pan offset | Dart addition |
| `setPan` clamps effective pan to ±1.0 | Both clamps |
| Master `setVolume` re-applies to all live instances | Registry iteration |
| Master `setPan` re-applies to all live instances | Registry iteration |
| Disposed instance skipped during master propagation | `_isDisposed` guard |
| `reset()` restores defaults and re-applies | Reset behaviour |
| `StateError` after dispose on `setVolume`/`setPan` | Dispose guard |

**Existing tests:** `setVolume` and `setPan` tests that assert `ArgumentError` for out-of-range values must be removed (behaviour now silently clamps).

---

## Files Changed

| File | Change |
|------|--------|
| `lib/src/loop_audio_player.dart` | Add `_localVolume`, `_localPan`, registration; modify `setVolume`/`setPan`; add `LoopAudioMaster` class |
| `test/loop_audio_master_test.dart` | New — ~15 unit tests |
| `README.md` | Add `LoopAudioMaster` API section |

`LoopAudioMaster` is auto-exported via the existing `export 'src/loop_audio_player.dart'` in `lib/flutter_gapless_loop.dart`. No native changes required.
