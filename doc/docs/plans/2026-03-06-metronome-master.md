# MetronomeMaster Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add per-instance `setVolume`/`setPan` to `MetronomePlayer` and a new `MetronomeMaster` static class that multiplicatively propagates volume/pan to all live instances.

**Architecture:** Dart handles all effective-value computation (`effectiveVolume = localVolume × masterVolume`, `effectivePan = clamp(localPan + masterPan, −1, 1)`). Native engines receive only the final float — no master logic in native. `MetronomeMaster` keeps a static `Set<MetronomePlayer>` registry; instances register on construction and unregister on dispose.

**Tech Stack:** Dart (Flutter method channels), Swift (AVAudioMixerNode volume/pan), Kotlin (AudioTrack setStereoVolume via panToGains)

---

### Task 1: Write failing Dart tests (TDD)

**Files:**
- Create: `test/metronome_master_test.dart`

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
      const MethodChannel('flutter_gapless_loop/metronome'),
      (call) async { calls.add(call); return null; },
    );
    // Reset master state between tests
    MetronomeMaster._masterVolume = 1.0;
    MetronomeMaster._masterPan    = 0.0;
    MetronomeMaster._instances.clear();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('flutter_gapless_loop/metronome'), null);
  });

  group('MetronomePlayer.setVolume', () {
    test('sends localVolume × masterVolume (1.0 default) to native', () async {
      final m = MetronomePlayer();
      await m.setVolume(0.8);
      expect(calls.last.method, 'setVolume');
      final args = calls.last.arguments as Map;
      expect(args['volume'], closeTo(0.8, 0.001));
      expect(args['playerId'], equals(m.playerId));
    });

    test('multiplies by master volume when master != 1.0', () async {
      await MetronomeMaster.setVolume(0.5);
      calls.clear();
      final m = MetronomePlayer();
      await m.setVolume(0.8);
      final args = calls.last.arguments as Map;
      expect(args['volume'], closeTo(0.4, 0.001)); // 0.8 × 0.5
    });

    test('clamps effective volume to 1.0', () async {
      final m = MetronomePlayer();
      await m.setVolume(1.1); // clamped to 1.0
      final args = calls.last.arguments as Map;
      expect(args['volume'], closeTo(1.0, 0.001));
    });

    test('throws StateError after dispose', () async {
      final m = MetronomePlayer();
      await m.dispose();
      expect(() => m.setVolume(0.5), throwsStateError);
    });
  });

  group('MetronomePlayer.setPan', () {
    test('sends localPan + masterPan (0.0 default) to native', () async {
      final m = MetronomePlayer();
      await m.setPan(0.6);
      expect(calls.last.method, 'setPan');
      final args = calls.last.arguments as Map;
      expect(args['pan'], closeTo(0.6, 0.001));
      expect(args['playerId'], equals(m.playerId));
    });

    test('adds master pan offset', () async {
      await MetronomeMaster.setPan(0.3);
      calls.clear();
      final m = MetronomePlayer();
      await m.setPan(0.5);
      final args = calls.last.arguments as Map;
      expect(args['pan'], closeTo(0.8, 0.001)); // 0.5 + 0.3
    });

    test('clamps effective pan to 1.0', () async {
      await MetronomeMaster.setPan(0.5);
      calls.clear();
      final m = MetronomePlayer();
      await m.setPan(0.8); // 0.8 + 0.5 = 1.3 → clamped to 1.0
      final args = calls.last.arguments as Map;
      expect(args['pan'], closeTo(1.0, 0.001));
    });

    test('clamps effective pan to -1.0', () async {
      await MetronomeMaster.setPan(-0.5);
      calls.clear();
      final m = MetronomePlayer();
      await m.setPan(-0.8); // -0.8 + -0.5 = -1.3 → clamped to -1.0
      final args = calls.last.arguments as Map;
      expect(args['pan'], closeTo(-1.0, 0.001));
    });

    test('throws StateError after dispose', () async {
      final m = MetronomePlayer();
      await m.dispose();
      expect(() => m.setPan(0.5), throwsStateError);
    });
  });

  group('MetronomeMaster.setVolume', () {
    test('re-applies effective volume to all live instances', () async {
      final m1 = MetronomePlayer();
      final m2 = MetronomePlayer();
      await m1.setVolume(0.8);
      await m2.setVolume(0.6);
      calls.clear();

      await MetronomeMaster.setVolume(0.5);

      // Both instances should have received new effective volumes
      final volumeCalls = calls.where((c) => c.method == 'setVolume').toList();
      expect(volumeCalls, hasLength(2));
      final vols = volumeCalls.map((c) => c.arguments['volume'] as double).toSet();
      expect(vols, containsAll([closeTo(0.4, 0.001), closeTo(0.3, 0.001)]));
    });

    test('skips disposed instances', () async {
      final m1 = MetronomePlayer();
      final m2 = MetronomePlayer();
      await m2.dispose();
      calls.clear();

      await MetronomeMaster.setVolume(0.5);

      final volumeCalls = calls.where((c) => c.method == 'setVolume').toList();
      expect(volumeCalls, hasLength(1));
    });

    test('exposes current value via getter', () async {
      await MetronomeMaster.setVolume(0.7);
      expect(MetronomeMaster.volume, closeTo(0.7, 0.001));
    });
  });

  group('MetronomeMaster.setPan', () {
    test('re-applies effective pan to all live instances', () async {
      final m1 = MetronomePlayer();
      final m2 = MetronomePlayer();
      await m1.setPan(0.4);
      await m2.setPan(-0.2);
      calls.clear();

      await MetronomeMaster.setPan(0.2);

      final panCalls = calls.where((c) => c.method == 'setPan').toList();
      expect(panCalls, hasLength(2));
      final pans = panCalls.map((c) => c.arguments['pan'] as double).toSet();
      expect(pans, containsAll([closeTo(0.6, 0.001), closeTo(0.0, 0.001)]));
    });

    test('exposes current value via getter', () async {
      await MetronomeMaster.setPan(-0.3);
      expect(MetronomeMaster.pan, closeTo(-0.3, 0.001));
    });
  });

  group('MetronomeMaster.reset', () {
    test('restores defaults and re-applies to all instances', () async {
      await MetronomeMaster.setVolume(0.5);
      await MetronomeMaster.setPan(0.4);
      final m = MetronomePlayer();
      await m.setVolume(0.8);
      await m.setPan(0.3);
      calls.clear();

      await MetronomeMaster.reset();

      expect(MetronomeMaster.volume, 1.0);
      expect(MetronomeMaster.pan, 0.0);
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
flutter test test/metronome_master_test.dart
```

Expected: FAIL — `MetronomeMaster` not defined, `setVolume`/`setPan` not on `MetronomePlayer`.

---

### Task 2: Implement Dart — `MetronomePlayer` additions + `MetronomeMaster`

**Files:**
- Modify: `lib/src/metronome_player.dart`

**Step 1: Read the current file**

Read `lib/src/metronome_player.dart` to see its current state.

**Step 2: Add `_localVolume`, `_localPan`, registration, `setVolume`, `setPan`, and `_applyEffective*` helpers to `MetronomePlayer`**

After the `_isDisposed` field and before `MetronomePlayer()` constructor, add:

```dart
double _localVolume = 1.0;
double _localPan    = 0.0;
```

Change the constructor to:
```dart
MetronomePlayer() {
  _events = _sharedEvents.where((e) => e['playerId'] == _playerId);
  MetronomeMaster._instances.add(this);
}
```

Change `dispose()` to:
```dart
Future<void> dispose() async {
  _isDisposed = true;
  MetronomeMaster._instances.remove(this);
  await _channel.invokeMethod<void>('dispose', {'playerId': _playerId});
}
```

Add these methods after `setBeatsPerBar`:
```dart
/// Sets this instance's volume (0.0–1.0).
/// The effective volume sent to native is `localVolume × MetronomeMaster.volume`.
Future<void> setVolume(double volume) async {
  _checkNotDisposed();
  _localVolume = volume.clamp(0.0, 1.0);
  await _applyEffectiveVolume();
}

/// Sets this instance's stereo pan position (−1.0 to 1.0).
/// The effective pan sent to native is `clamp(localPan + MetronomeMaster.pan, −1.0, 1.0)`.
Future<void> setPan(double pan) async {
  _checkNotDisposed();
  _localPan = pan.clamp(-1.0, 1.0);
  await _applyEffectivePan();
}

Future<void> _applyEffectiveVolume() async {
  final effective = (_localVolume * MetronomeMaster._masterVolume).clamp(0.0, 1.0);
  await _channel.invokeMethod<void>(
      'setVolume', {'playerId': _playerId, 'volume': effective});
}

Future<void> _applyEffectivePan() async {
  final effective = (_localPan + MetronomeMaster._masterPan).clamp(-1.0, 1.0);
  await _channel.invokeMethod<void>(
      'setPan', {'playerId': _playerId, 'pan': effective});
}
```

**Step 3: Add `MetronomeMaster` class at the bottom of the same file** (after the closing `}` of `MetronomePlayer`)

```dart
/// A static group-bus controller for all live [MetronomePlayer] instances.
///
/// Volume is multiplicative: `effectiveVolume = localVolume × masterVolume`.
/// Pan is additive (clamped): `effectivePan = clamp(localPan + masterPan, −1.0, 1.0)`.
///
/// ## Example
/// ```dart
/// final m1 = MetronomePlayer();
/// final m2 = MetronomePlayer();
/// await m1.setVolume(0.8);
/// await m2.setVolume(0.6);
/// await MetronomeMaster.setVolume(0.5); // m1 → 0.4, m2 → 0.3
/// ```
class MetronomeMaster {
  MetronomeMaster._();

  static final Set<MetronomePlayer> _instances = {};
  static double _masterVolume = 1.0;
  static double _masterPan    = 0.0;

  /// Current master volume (0.0–1.0). Default: `1.0`.
  static double get volume => _masterVolume;

  /// Current master pan (−1.0–1.0). Default: `0.0`.
  static double get pan => _masterPan;

  /// Scales all live [MetronomePlayer] instances multiplicatively.
  ///
  /// Each instance's effective volume becomes `localVolume × volume`.
  static Future<void> setVolume(double volume) async {
    _masterVolume = volume.clamp(0.0, 1.0);
    for (final inst in _instances) {
      if (!inst._isDisposed) await inst._applyEffectiveVolume();
    }
  }

  /// Shifts all live [MetronomePlayer] pans by [pan] (additive, clamped to ±1.0).
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
}
```

**Step 4: Run the tests**

```
flutter test test/metronome_master_test.dart
```

Expected: All tests pass (tests access `MetronomeMaster._masterVolume` etc. directly since they're in the same package-internal scope).

Note: The `setUp` block resets `MetronomeMaster._masterVolume`, `._masterPan`, and `._instances` to avoid state leaking between tests. Since these are private to the library but accessible from test via `package:flutter_gapless_loop`, this works fine in Dart's test framework when using `flutter_test`.

**Step 5: Run all Dart tests**

```
flutter test
```

Expected: All tests pass (existing metronome tests unaffected since `setVolume`/`setPan` are new methods).

**Step 6: Commit**

```bash
git add lib/src/metronome_player.dart test/metronome_master_test.dart
git commit -m "feat: add MetronomePlayer setVolume/setPan + MetronomeMaster group-bus controller"
```

---

### Task 3: iOS `MetronomeEngine` — add `setVolume` / `setPan`

**Files:**
- Modify: `ios/Classes/MetronomeEngine.swift`

**Step 1: Add stored fields after `private var isRunning = false`**

```swift
private var _volume: Float = 1.0
private var _pan:    Float = 0.0
```

**Step 2: Add public `setVolume` and `setPan` methods after `setBeatsPerBar`**

```swift
/// Sets the playback volume (0.0–1.0). Takes effect immediately and persists across rebuilds.
func setVolume(_ volume: Float) {
    _volume = volume
    audioEngine.mainMixerNode.volume = volume
}

/// Sets the stereo pan position (−1.0 to 1.0). Takes effect immediately and persists across rebuilds.
func setPan(_ pan: Float) {
    _pan = pan
    audioEngine.mainMixerNode.pan = pan
}
```

**Step 3: Re-apply volume and pan in `setupAndPlay` after `audioEngine.start()`**

In `setupAndPlay`, after the `try audioEngine.start()` block (before scheduling the buffer), add:

```swift
// Re-apply stored volume and pan — mainMixerNode is recreated with each new AVAudioEngine.
audioEngine.mainMixerNode.volume = _volume
audioEngine.mainMixerNode.pan    = _pan
```

The full `setupAndPlay` after this change:

```swift
private func setupAndPlay(format: AVAudioFormat) {
    if audioEngine.isRunning { audioEngine.stop() }
    audioEngine = AVAudioEngine()
    playerNode  = AVAudioPlayerNode()

    audioEngine.attach(playerNode)
    audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)

    do {
        try audioEngine.start()
    } catch {
        onError?("AVAudioEngine.start() failed: \(error.localizedDescription)")
        return
    }

    // Re-apply stored volume and pan after engine rebuild.
    audioEngine.mainMixerNode.volume = _volume
    audioEngine.mainMixerNode.pan    = _pan

    guard let bar = barBuffer else { return }
    playerNode.scheduleBuffer(bar, at: nil, options: .loops, completionHandler: nil)
    playerNode.play()
}
```

**Step 4: No unit tests for iOS native** — the logic is verified by Dart tests and the iOS build check. Proceed to commit after build (Task 5).

---

### Task 4: iOS plugin bridge — add `setVolume` / `setPan` cases

**Files:**
- Modify: `ios/Classes/FlutterGaplessLoopPlugin.swift`

**Step 1: Add `setVolume` and `setPan` cases inside `handleMetronomeCall`**

Find the `case "stop":` line inside `handleMetronomeCall`. Add before it:

```swift
case "setVolume":
    guard let vol = args?["volume"] as? Double else {
        result(FlutterError(code: "INVALID_ARGS", message: "'volume' required", details: nil))
        return
    }
    metronomes[pid]?.setVolume(Float(vol))
    result(nil)

case "setPan":
    guard let pan = args?["pan"] as? Double else {
        result(FlutterError(code: "INVALID_ARGS", message: "'pan' required", details: nil))
        return
    }
    metronomes[pid]?.setPan(Float(pan))
    result(nil)
```

**Step 2: Build iOS to verify**

```
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop/example
flutter build ios --no-codesign 2>&1 | tail -5
```

Expected: `Xcode build done.` with no errors.

**Step 3: Commit iOS changes**

```bash
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop
git add ios/Classes/MetronomeEngine.swift ios/Classes/FlutterGaplessLoopPlugin.swift
git commit -m "feat(ios): add setVolume/setPan to MetronomeEngine and metronome bridge"
```

---

### Task 5: Android `MetronomeEngine` — add `setVolume` / `setPan`

**Files:**
- Modify: `android/src/main/kotlin/com/fluttergaplessloop/MetronomeEngine.kt`

**Step 1: Add stored fields after `private var isRunning = false`**

```kotlin
private var _volume: Float = 1.0f
private var _pan:    Float = 0.0f
```

**Step 2: Add `setVolume`, `setPan`, and `applyVolumeAndPan` methods after `dispose()`**

```kotlin
/** Sets the playback volume (0.0–1.0). Takes effect immediately and persists across rebuilds. */
fun setVolume(volume: Float) {
    _volume = volume
    applyVolumeAndPan()
}

/** Sets the stereo pan (−1.0 to 1.0). Takes effect immediately and persists across rebuilds. */
fun setPan(pan: Float) {
    _pan = pan
    applyVolumeAndPan()
}

private fun applyVolumeAndPan() {
    val track = audioTrack ?: return
    val (l, r) = panToGains(_pan)   // top-level fun in BpmDetector.kt
    track.setStereoVolume(_volume * l, _volume * r)
}
```

**Step 3: Call `applyVolumeAndPan()` at the end of `playBarBuffer`**

In `playBarBuffer`, after `track.play()` and `audioTrack = track`, add:

```kotlin
applyVolumeAndPan()
```

The end of `playBarBuffer` after this change:

```kotlin
track.write(pcmShort, 0, pcmShort.size)
track.setLoopPoints(0, barFrames, -1)
track.play()
audioTrack = track
applyVolumeAndPan()   // ← re-apply stored volume and pan after each rebuild
```

**Step 4: Run Android unit tests**

```
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop/example/android
./gradlew :flutter_gapless_loop:test 2>&1 | tail -10
```

Expected: `BUILD SUCCESSFUL` — existing tests unaffected (new methods not unit-tested; logic is in Dart).

---

### Task 6: Android plugin bridge — add `setVolume` / `setPan` cases

**Files:**
- Modify: `android/src/main/kotlin/com/fluttergaplessloop/FlutterGaplessLoopPlugin.kt`

**Step 1: Add `setVolume` and `setPan` cases in `handleMetronomeCall`**

Find `"stop" ->` inside `handleMetronomeCall`. Add before it:

```kotlin
"setVolume" -> {
    val volume = call.argument<Double>("volume")?.toFloat()
        ?: return result.error("INVALID_ARGS", "'volume' required", null)
    metronomes[playerId]?.setVolume(volume)
    result.success(null)
}

"setPan" -> {
    val pan = call.argument<Double>("pan")?.toFloat()
        ?: return result.error("INVALID_ARGS", "'pan' required", null)
    metronomes[playerId]?.setPan(pan)
    result.success(null)
}
```

**Step 2: Run Android unit tests again to confirm no regressions**

```
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop/example/android
./gradlew :flutter_gapless_loop:test 2>&1 | tail -5
```

Expected: `BUILD SUCCESSFUL`.

**Step 3: Commit Android changes**

```bash
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop
git add android/src/main/kotlin/com/fluttergaplessloop/MetronomeEngine.kt \
        android/src/main/kotlin/com/fluttergaplessloop/FlutterGaplessLoopPlugin.kt
git commit -m "feat(android): add setVolume/setPan to MetronomeEngine and metronome bridge"
```

---

### Task 7: Export `MetronomeMaster` + README

**Files:**
- Modify: `lib/flutter_gapless_loop.dart`
- Modify: `README.md`

**Step 1: Export `MetronomeMaster` from the barrel file**

Read `lib/flutter_gapless_loop.dart`. `MetronomeMaster` lives in `metronome_player.dart`, so it's already exported via:
```dart
export 'src/metronome_player.dart';
```
No barrel change needed — `MetronomeMaster` is in the same file as `MetronomePlayer`.

**Step 2: Add `MetronomeMaster` to README**

Find the `MetronomePlayer` API table in README.md and add a new section after it:

```markdown
### MetronomeMaster — group-bus control

`MetronomeMaster` is a static class that applies master volume and pan across all live
`MetronomePlayer` instances multiplicatively. Per-instance relative levels are preserved.

```dart
await MetronomeMaster.setVolume(0.5); // all instances scaled by 0.5
await MetronomeMaster.setPan(0.2);    // all instances shifted right by 0.2
await MetronomeMaster.reset();        // restore volume=1.0, pan=0.0
```

| Member | Description |
|--------|-------------|
| `volume` | Current master volume getter (default `1.0`) |
| `pan` | Current master pan getter (default `0.0`) |
| `setVolume(double)` | Scales all live instances: `effectiveVolume = localVolume × masterVolume` |
| `setPan(double)` | Shifts all live instances: `effectivePan = clamp(localPan + masterPan, −1, 1)` |
| `reset()` | Restores 1.0 / 0.0 and re-applies to all instances |
```

**Step 3: Run `flutter analyze`**

```
flutter analyze
```

Expected: No issues.

**Step 4: Commit**

```bash
git add README.md
git commit -m "docs: add MetronomeMaster API to README"
```

---

### Task 8: Build verification

**Step 1: Run all Dart tests**

```
flutter test
```

Expected: All tests pass (existing 41 + new metronome_master tests).

**Step 2: Run flutter analyze**

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

## Summary of all files changed

| File | Change |
|------|--------|
| `lib/src/metronome_player.dart` | Add `_localVolume`, `_localPan`, registration, `setVolume`, `setPan`, `_applyEffective*`; add `MetronomeMaster` class at bottom |
| `ios/Classes/MetronomeEngine.swift` | Add `_volume`, `_pan` fields; add `setVolume`, `setPan`; re-apply in `setupAndPlay` |
| `ios/Classes/FlutterGaplessLoopPlugin.swift` | Add `setVolume`/`setPan` cases in `handleMetronomeCall` |
| `android/.../MetronomeEngine.kt` | Add `_volume`, `_pan` fields; add `setVolume`, `setPan`, `applyVolumeAndPan`; call at end of `playBarBuffer` |
| `android/.../FlutterGaplessLoopPlugin.kt` | Add `setVolume`/`setPan` cases in `handleMetronomeCall` |
| `test/metronome_master_test.dart` | New — ~15 unit tests covering both `MetronomePlayer` and `MetronomeMaster` |
| `README.md` | Add `MetronomeMaster` API section |
