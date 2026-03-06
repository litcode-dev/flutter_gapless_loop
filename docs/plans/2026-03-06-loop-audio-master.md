# LoopAudioMaster Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add per-instance local-value tracking to `LoopAudioPlayer.setVolume`/`setPan` and a new `LoopAudioMaster` static class that multiplicatively propagates master volume/pan to all live instances.

**Architecture:** Pure Dart — no native changes. `LoopAudioPlayer` gets `_localVolume`/`_localPan` fields and private `_applyEffective*` helpers. `LoopAudioMaster` (same file, same library) holds a static `Set<LoopAudioPlayer>` registry; instances register on construction, unregister on dispose. Effective values: `effectiveVolume = localVolume × masterVolume`, `effectivePan = clamp(localPan + masterPan, −1, 1)`.

**Tech Stack:** Dart (Flutter method channels). No native (Swift/Kotlin) changes required.

---

### Task 1: Write failing Dart tests (TDD)

**Files:**
- Create: `test/loop_audio_master_test.dart`

**Step 1: Write the test file**

```dart
import 'package:flutter/services.dart';
import 'package:flutter_gapless_loop/flutter_gapless_loop.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('flutter_gapless_loop'),
      (call) async {
        calls.add(call);
        return null;
      },
    );
    // Reset master state between tests (uses @visibleForTesting helper).
    LoopAudioMaster.resetForTesting();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('flutter_gapless_loop'), null);
  });

  group('LoopAudioPlayer.setVolume', () {
    test('sends localVolume × masterVolume (1.0 default) to native', () async {
      final p = LoopAudioPlayer();
      await p.setVolume(0.8);
      expect(calls.last.method, 'setVolume');
      final args = calls.last.arguments as Map;
      expect(args['volume'], closeTo(0.8, 0.001));
      expect(args['playerId'], equals(p.playerId));
    });

    test('multiplies by master volume when master != 1.0', () async {
      await LoopAudioMaster.setVolume(0.5);
      calls.clear();
      final p = LoopAudioPlayer();
      await p.setVolume(0.8);
      final args = calls.last.arguments as Map;
      expect(args['volume'], closeTo(0.4, 0.001)); // 0.8 × 0.5
    });

    test('clamps effective volume to 1.0', () async {
      final p = LoopAudioPlayer();
      await p.setVolume(1.1); // local clamped to 1.0, effective = 1.0 × 1.0
      final args = calls.last.arguments as Map;
      expect(args['volume'], closeTo(1.0, 0.001));
    });

    test('throws StateError after dispose', () async {
      final p = LoopAudioPlayer();
      await p.dispose();
      expect(() => p.setVolume(0.5), throwsStateError);
    });
  });

  group('LoopAudioPlayer.setPan', () {
    test('sends localPan + masterPan (0.0 default) to native', () async {
      final p = LoopAudioPlayer();
      await p.setPan(0.6);
      expect(calls.last.method, 'setPan');
      final args = calls.last.arguments as Map;
      expect(args['pan'], closeTo(0.6, 0.001));
      expect(args['playerId'], equals(p.playerId));
    });

    test('adds master pan offset', () async {
      await LoopAudioMaster.setPan(0.3);
      calls.clear();
      final p = LoopAudioPlayer();
      await p.setPan(0.5);
      final args = calls.last.arguments as Map;
      expect(args['pan'], closeTo(0.8, 0.001)); // 0.5 + 0.3
    });

    test('clamps effective pan to 1.0', () async {
      await LoopAudioMaster.setPan(0.5);
      calls.clear();
      final p = LoopAudioPlayer();
      await p.setPan(0.8); // 0.8 + 0.5 = 1.3 → clamped to 1.0
      final args = calls.last.arguments as Map;
      expect(args['pan'], closeTo(1.0, 0.001));
    });

    test('clamps effective pan to -1.0', () async {
      await LoopAudioMaster.setPan(-0.5);
      calls.clear();
      final p = LoopAudioPlayer();
      await p.setPan(-0.8); // -0.8 + -0.5 = -1.3 → clamped to -1.0
      final args = calls.last.arguments as Map;
      expect(args['pan'], closeTo(-1.0, 0.001));
    });

    test('throws StateError after dispose', () async {
      final p = LoopAudioPlayer();
      await p.dispose();
      expect(() => p.setPan(0.5), throwsStateError);
    });
  });

  group('LoopAudioMaster.setVolume', () {
    test('re-applies effective volume to all live instances', () async {
      final p1 = LoopAudioPlayer();
      final p2 = LoopAudioPlayer();
      await p1.setVolume(0.8);
      await p2.setVolume(0.6);
      calls.clear();

      await LoopAudioMaster.setVolume(0.5);

      final volumeCalls = calls.where((c) => c.method == 'setVolume').toList();
      expect(volumeCalls, hasLength(2));
      final vols =
          volumeCalls.map((c) => c.arguments['volume'] as double).toSet();
      expect(vols, containsAll([closeTo(0.4, 0.001), closeTo(0.3, 0.001)]));
    });

    test('skips disposed instances', () async {
      LoopAudioPlayer(); // live instance in registry, not otherwise used
      final p2 = LoopAudioPlayer();
      await p2.dispose();
      calls.clear();

      await LoopAudioMaster.setVolume(0.5);

      final volumeCalls = calls.where((c) => c.method == 'setVolume').toList();
      expect(volumeCalls, hasLength(1));
    });

    test('exposes current value via getter', () async {
      await LoopAudioMaster.setVolume(0.7);
      expect(LoopAudioMaster.volume, closeTo(0.7, 0.001));
    });
  });

  group('LoopAudioMaster.setPan', () {
    test('re-applies effective pan to all live instances', () async {
      final p1 = LoopAudioPlayer();
      final p2 = LoopAudioPlayer();
      await p1.setPan(0.4);
      await p2.setPan(-0.2);
      calls.clear();

      await LoopAudioMaster.setPan(0.2);

      final panCalls = calls.where((c) => c.method == 'setPan').toList();
      expect(panCalls, hasLength(2));
      final pans = panCalls.map((c) => c.arguments['pan'] as double).toSet();
      expect(pans, containsAll([closeTo(0.6, 0.001), closeTo(0.0, 0.001)]));
    });

    test('exposes current value via getter', () async {
      await LoopAudioMaster.setPan(-0.3);
      expect(LoopAudioMaster.pan, closeTo(-0.3, 0.001));
    });
  });

  group('LoopAudioMaster.reset', () {
    test('restores defaults and re-applies to all instances', () async {
      await LoopAudioMaster.setVolume(0.5);
      await LoopAudioMaster.setPan(0.4);
      final p = LoopAudioPlayer();
      await p.setVolume(0.8);
      await p.setPan(0.3);
      calls.clear();

      await LoopAudioMaster.reset();

      expect(LoopAudioMaster.volume, 1.0);
      expect(LoopAudioMaster.pan, 0.0);
      // effective volume = 0.8 × 1.0 = 0.8; effective pan = 0.3 + 0.0 = 0.3
      final vCall = calls.firstWhere((c) => c.method == 'setVolume');
      expect(vCall.arguments['volume'], closeTo(0.8, 0.001));
      final pCall = calls.firstWhere((c) => c.method == 'setPan');
      expect(pCall.arguments['pan'], closeTo(0.3, 0.001));
    });
  });
}
```

**Step 2: Run the test to verify it fails**

```
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop
flutter test test/loop_audio_master_test.dart
```

Expected: FAIL — `LoopAudioMaster` not defined.

---

### Task 2: Implement Dart — `LoopAudioPlayer` modifications + `LoopAudioMaster`

**Files:**
- Modify: `lib/src/loop_audio_player.dart`

**Step 1: Read the current file**

Read `lib/src/loop_audio_player.dart` to confirm current state.

**Step 2: Add `foundation.dart` import**

After the existing imports at the top of the file, add:

```dart
import 'package:flutter/foundation.dart';
```

So the import block becomes:

```dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'loop_audio_state.dart';
```

**Step 3: Add `_localVolume`, `_localPan` fields and update constructor**

Find the `bool _isDisposed = false;` line. Add the two fields after it:

```dart
bool _isDisposed = false;
double _localVolume = 1.0;
double _localPan    = 0.0;
```

Change the constructor from:

```dart
LoopAudioPlayer() {
  _events = _sharedEvents.where((e) => e['playerId'] == _playerId);
}
```

To:

```dart
LoopAudioPlayer() {
  _events = _sharedEvents.where((e) => e['playerId'] == _playerId);
  LoopAudioMaster._instances.add(this);
}
```

**Step 4: Update `dispose()` to unregister**

Change `dispose()` from:

```dart
Future<void> dispose() async {
  _isDisposed = true;
  await _channel.invokeMethod<void>('dispose', {'playerId': _playerId});
}
```

To:

```dart
Future<void> dispose() async {
  _isDisposed = true;
  LoopAudioMaster._instances.remove(this);
  await _channel.invokeMethod<void>('dispose', {'playerId': _playerId});
}
```

**Step 5: Replace `setVolume` and `setPan` with local-tracking versions**

Replace the existing `setVolume`:

```dart
/// Sets the playback volume. Range: 0.0 (silent) to 1.0 (full volume).
///
/// Values outside the range are clamped. The effective volume sent to native
/// is `localVolume × LoopAudioMaster.volume`.
Future<void> setVolume(double volume) async {
  _checkNotDisposed();
  _localVolume = volume.clamp(0.0, 1.0);
  await _applyEffectiveVolume();
}
```

Replace the existing `setPan`:

```dart
/// Sets the stereo pan position.
///
/// [pan] is in [-1.0, 1.0]:
/// - `-1.0` = full left
/// - `0.0`  = centre (default)
/// - `1.0`  = full right
///
/// Values outside the range are clamped. The effective pan sent to native
/// is `clamp(localPan + LoopAudioMaster.pan, −1.0, 1.0)`.
Future<void> setPan(double pan) async {
  _checkNotDisposed();
  _localPan = pan.clamp(-1.0, 1.0);
  await _applyEffectivePan();
}
```

**Step 6: Add the private `_applyEffective*` helpers**

Add these two methods directly after `setPan` (before `setPlaybackRate`):

```dart
Future<void> _applyEffectiveVolume() async {
  final effective =
      (_localVolume * LoopAudioMaster._masterVolume).clamp(0.0, 1.0);
  await _channel.invokeMethod<void>(
      'setVolume', {'playerId': _playerId, 'volume': effective});
}

Future<void> _applyEffectivePan() async {
  final effective =
      (_localPan + LoopAudioMaster._masterPan).clamp(-1.0, 1.0);
  await _channel.invokeMethod<void>(
      'setPan', {'playerId': _playerId, 'pan': effective});
}
```

**Step 7: Add `LoopAudioMaster` class at the bottom of the file**

After the closing `}` of `LoopAudioPlayer`, append:

```dart
/// A static group-bus controller for all live [LoopAudioPlayer] instances.
///
/// Volume is multiplicative: `effectiveVolume = localVolume × masterVolume`.
/// Pan is additive (clamped): `effectivePan = clamp(localPan + masterPan, −1.0, 1.0)`.
///
/// ## Example
/// ```dart
/// final p1 = LoopAudioPlayer();
/// final p2 = LoopAudioPlayer();
/// await p1.setVolume(0.8);
/// await p2.setVolume(0.6);
/// await LoopAudioMaster.setVolume(0.5); // p1 → 0.4, p2 → 0.3
/// ```
class LoopAudioMaster {
  LoopAudioMaster._();

  static final Set<LoopAudioPlayer> _instances = {};
  static double _masterVolume = 1.0;
  static double _masterPan    = 0.0;

  /// Current master volume (0.0–1.0). Default: `1.0`.
  static double get volume => _masterVolume;

  /// Current master pan (−1.0–1.0). Default: `0.0`.
  static double get pan => _masterPan;

  /// Scales all live [LoopAudioPlayer] instances multiplicatively.
  ///
  /// Each instance's effective volume becomes `localVolume × volume`.
  static Future<void> setVolume(double volume) async {
    _masterVolume = volume.clamp(0.0, 1.0);
    for (final inst in _instances) {
      if (!inst._isDisposed) await inst._applyEffectiveVolume();
    }
  }

  /// Shifts all live [LoopAudioPlayer] pans by [pan] (additive, clamped to ±1.0).
  static Future<void> setPan(double pan) async {
    _masterPan = pan.clamp(-1.0, 1.0);
    for (final inst in _instances) {
      if (!inst._isDisposed) await inst._applyEffectivePan();
    }
  }

  /// Resets master volume to 1.0 and pan to 0.0, then re-applies to all instances.
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

  /// Resets master state for use in tests only.
  @visibleForTesting
  static void resetForTesting() {
    _masterVolume = 1.0;
    _masterPan    = 0.0;
    _instances.clear();
  }
}
```

**Step 8: Run the new tests**

```
flutter test test/loop_audio_master_test.dart
```

Expected: All tests pass.

**Step 9: Run the full test suite**

```
flutter test
```

Expected: All tests pass (existing tests unaffected — no `LoopAudioPlayer.setVolume` `ArgumentError` tests exist to remove).

**Step 10: Commit**

```bash
git add lib/src/loop_audio_player.dart test/loop_audio_master_test.dart
git commit -m "feat: add LoopAudioPlayer local volume/pan + LoopAudioMaster group-bus controller"
```

---

### Task 3: README + `flutter analyze`

**Files:**
- Modify: `README.md`

**Step 1: Add `LoopAudioPlayer` new row to existing API table**

Find the `LoopAudioPlayer` API table in `README.md`. The existing rows include `setVolume` and `setPan`. Update their descriptions to mention the master interaction:

Find:
```markdown
| `setVolume(double volume)` | Volume in `[0.0, 1.0]`. |
| `setPan(double pan)` | Stereo pan in `[-1.0, 1.0]`. Values clamped. |
```

Replace with:
```markdown
| `setVolume(double volume)` | Instance volume in `[0.0, 1.0]`. Effective volume = `localVolume × LoopAudioMaster.volume`. Values clamped. |
| `setPan(double pan)` | Instance pan in `[-1.0, 1.0]`. Effective pan = `clamp(localPan + LoopAudioMaster.pan, -1, 1)`. Values clamped. |
```

**Step 2: Add `LoopAudioMaster` section after the `LoopAudioPlayer` API table**

Find the line `### `MetronomePlayer`` in `README.md`. Insert a new section immediately before it:

```markdown
### `LoopAudioMaster`

`LoopAudioMaster` is a static class that applies master volume and pan across all live `LoopAudioPlayer` instances. Per-instance relative levels are preserved.

```dart
await LoopAudioMaster.setVolume(0.5); // all instances scaled by 0.5
await LoopAudioMaster.setPan(0.2);    // all instances shifted right by 0.2
await LoopAudioMaster.reset();        // restore volume=1.0, pan=0.0
```

| Member | Description |
|--------|-------------|
| `volume` | Current master volume getter (default `1.0`) |
| `pan` | Current master pan getter (default `0.0`) |
| `setVolume(double volume)` | Scales all live instances: `effectiveVolume = localVolume × masterVolume` |
| `setPan(double pan)` | Shifts all live instances: `effectivePan = clamp(localPan + masterPan, -1, 1)` |
| `reset()` | Restores `volume=1.0` / `pan=0.0` and re-applies to all instances |

```

**Step 3: Run `flutter analyze`**

```
flutter analyze
```

Expected: No issues found.

**Step 4: Commit**

```bash
git add README.md
git commit -m "docs: add LoopAudioMaster API to README"
```

---

### Task 4: Build verification

**Step 1: Run all Dart tests**

```
flutter test
```

Expected: All tests pass.

**Step 2: Run `flutter analyze`**

```
flutter analyze
```

Expected: No issues found.

**Step 3: Build iOS**

```
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop/example
flutter build ios --no-codesign 2>&1 | tail -5
```

Expected: `Xcode build done.`

**Step 4: Run Android unit tests**

```
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop/example/android
./gradlew :flutter_gapless_loop:test 2>&1 | tail -5
```

Expected: `BUILD SUCCESSFUL`.

---

## Summary of files changed

| File | Change |
|------|--------|
| `lib/src/loop_audio_player.dart` | Add `foundation.dart` import; add `_localVolume`, `_localPan` fields; register/unregister in constructor/dispose; modify `setVolume`/`setPan` to store and delegate; add `_applyEffective*` helpers; add `LoopAudioMaster` class at bottom |
| `test/loop_audio_master_test.dart` | New — ~15 unit tests |
| `README.md` | Update `setVolume`/`setPan` descriptions; add `LoopAudioMaster` section |
