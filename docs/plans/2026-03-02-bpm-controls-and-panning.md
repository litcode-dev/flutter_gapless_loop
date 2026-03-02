# BPM Controls + Panning Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add manual BPM input, ±1 BPM buttons, tap tempo, snap-to-beat (example app only), and `setPan(double)` plugin API to `flutter_gapless_loop`.

**Architecture:** BPM controls live entirely in the example app (pure UI state, no native changes needed). Panning is a new plugin API method that calls `mixerNode.pan` on iOS (1-line; mixer already in signal chain) and `AudioTrack.setStereoVolume` (equal-power formula) on Android. The Android equal-power formula is extracted as `internal fun panToGains(pan: Float): Pair<Float, Float>` so it can be unit-tested.

**Tech Stack:** Flutter/Dart method channel, Swift AVAudioMixerNode, Kotlin AudioTrack.

---

### Task 1: Dart — add `setPan` to `LoopAudioPlayer`

**Files:**
- Modify: `lib/src/loop_audio_player.dart` (add method after `setVolume` at line 156)

No Dart unit test needed — method channel invocations are trivially correct and verified by Task 5 build.

**Step 1: Add `setPan` after `setVolume` (after line 156)**

Insert after the closing `}` of `setVolume`:

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
  await _channel.invokeMethod<void>('setPan', {'pan': pan.clamp(-1.0, 1.0)});
}
```

**Step 2: Verify no analysis errors**

Run: `flutter analyze lib/`
Expected: `No issues found!`

**Step 3: Commit**

```bash
git add lib/src/loop_audio_player.dart
git commit -m "feat: add setPan(double) to LoopAudioPlayer Dart API"
```

---

### Task 2: Android — `setPan` + equal-power formula + unit tests

**Files:**
- Modify: `android/src/main/kotlin/com/fluttergaplessloop/LoopAudioEngine.kt`
  - Add `internal fun panToGains(pan: Float): Pair<Float, Float>` as a top-level function in the file (before the class)
  - Add `@Volatile private var panValue: Float = 0f` field after `setVolume`
  - Add `fun setPan(pan: Float)` and `private fun applyPan()` after `setVolume`
  - Call `applyPan()` at end of `buildAudioTrack()` (line 484, after the `Log.i`)
- Modify: `android/src/main/kotlin/com/fluttergaplessloop/FlutterGaplessLoopPlugin.kt`
  - Add `"setPan"` case after the `"setVolume"` case (after line 176)
- Modify: `android/src/test/kotlin/com/fluttergaplessloop/FlutterGaplessLoopPluginTest.kt`
  - Add `PanFormulaTest` class at the bottom

**Step 1: Write the failing test**

Add this class at the bottom of `FlutterGaplessLoopPluginTest.kt` (after `BpmDetectorTest`):

```kotlin
class PanFormulaTest {

    @Test
    fun `centre pan gives equal left and right gains`() {
        val (l, r) = panToGains(0f)
        assertEquals(l, r, 0.001f)
    }

    @Test
    fun `full left pan gives leftGain=1 rightGain=0`() {
        val (l, r) = panToGains(-1f)
        assertEquals(1.0f, l, 0.001f)
        assertEquals(0.0f, r, 0.001f)
    }

    @Test
    fun `full right pan gives leftGain=0 rightGain=1`() {
        val (l, r) = panToGains(1f)
        assertEquals(0.0f, l, 0.001f)
        assertEquals(1.0f, r, 0.001f)
    }

    @Test
    fun `centre gains satisfy equal-power property (sum of squares = 1)`() {
        val (l, r) = panToGains(0f)
        assertEquals(1.0f, l * l + r * r, 0.01f)
    }
}
```

**Step 2: Run test to verify it FAILS (panToGains not defined yet)**

Run: `cd android && ./gradlew test 2>&1 | tail -25`
Expected: FAIL — compilation error: `unresolved reference: panToGains`

**Step 3: Add `panToGains` as a top-level internal function in `LoopAudioEngine.kt`**

Add this just above the `class LoopAudioEngine` declaration (after the imports/ARCHITECTURE NOTE block):

```kotlin
/**
 * Equal-power pan formula.
 *
 * Maps [pan] ∈ [−1, 1] to (leftGain, rightGain) using:
 *   angle = (pan + 1) × π/4
 *   leftGain  = cos(angle)
 *   rightGain = sin(angle)
 *
 * At centre (pan=0):  angle=π/4 → both gains ≈ 0.707 (−3 dB each).
 * At full left (−1):  angle=0   → leftGain=1, rightGain=0.
 * At full right (+1): angle=π/2 → leftGain=0, rightGain=1.
 */
internal fun panToGains(pan: Float): Pair<Float, Float> {
    val angle = (pan + 1f) * (Math.PI.toFloat() / 4f)
    return Pair(kotlin.math.cos(angle), kotlin.math.sin(angle))
}
```

**Step 4: Run test again to confirm it passes**

Run: `cd android && ./gradlew test --tests "com.fluttergaplessloop.PanFormulaTest" 2>&1 | tail -10`
Expected: 4 tests, all PASS

**Step 5: Add `panValue`, `setPan`, and `applyPan` to `LoopAudioEngine`**

Insert after `setVolume` (after line 389 — the `}` closing `setVolume`):

```kotlin
/**
 * Sets the stereo pan position. [pan] is in [−1.0, 1.0].
 * Thread-safe via @Volatile + [AudioTrack.setStereoVolume].
 */
@Volatile private var panValue: Float = 0f

fun setPan(pan: Float) {
    panValue = pan.coerceIn(-1f, 1f)
    applyPan()
}

private fun applyPan() {
    val (leftGain, rightGain) = panToGains(panValue)
    audioTrack?.setStereoVolume(leftGain, rightGain)
}
```

**Step 6: Call `applyPan()` at end of `buildAudioTrack()`**

In `buildAudioTrack()`, add `applyPan()` as the last line before the closing `}` (after the `Log.i(TAG, "AudioTrack built: ...")` line 483):

```kotlin
applyPan() // Restore pan setting after AudioTrack recreation
```

**Step 7: Add `"setPan"` case to `FlutterGaplessLoopPlugin.kt`**

Insert after the `"setVolume"` case (after line 176):

```kotlin
"setPan" -> {
    val pan = call.argument<Double>("pan")?.toFloat() ?: 0f
    eng.setPan(pan)
    result.success(null)
}
```

**Step 8: Run all Android tests**

Run: `cd android && ./gradlew test 2>&1 | tail -20`
Expected: 26 tests, all PASS

**Step 9: Android build**

Run: `flutter build apk --debug 2>&1 | tail -5`
Expected: `✓ Built build/app/outputs/flutter-apk/app-debug.apk`

**Step 10: Commit**

```bash
git add android/src/main/kotlin/com/fluttergaplessloop/LoopAudioEngine.kt \
        android/src/main/kotlin/com/fluttergaplessloop/FlutterGaplessLoopPlugin.kt \
        android/src/test/kotlin/com/fluttergaplessloop/FlutterGaplessLoopPluginTest.kt
git commit -m "feat(android): add setPan with equal-power panToGains formula"
```

---

### Task 3: iOS — `setPan` in engine + plugin

**Files:**
- Modify: `ios/Classes/LoopAudioEngine.swift` (add `setPan` after `setVolume` at line 430)
- Modify: `ios/Classes/FlutterGaplessLoopPlugin.swift` (add `"setPan"` case after `"setVolume"` at line 228)

`AVAudioMixerNode.pan` is a built-in AVFoundation property with no custom logic. Build verification suffices.

**Step 1: Add `setPan` to `LoopAudioEngine.swift` after `setVolume` (after line 430)**

```swift
/// Sets the stereo pan position. Range: -1.0 (full left) to 1.0 (full right).
///
/// Delegates to `AVAudioMixerNode.pan`, which applies an equal-power curve
/// internally. Persists across loads — `mixerNode` is never torn down between loads.
public func setPan(_ pan: Float) {
    audioQueue.async { [weak self] in
        guard let self else { return }
        self.mixerNode.pan = max(-1.0, min(1.0, pan))
    }
}
```

**Step 2: Add `"setPan"` case to `FlutterGaplessLoopPlugin.swift` after `"setVolume"` (after line 228)**

```swift
case "setPan":
    guard let pan = args?["pan"] as? Double else {
        DispatchQueue.main.async { result(FlutterError(code: "INVALID_ARGS", message: "'pan' is required", details: nil)) }
        return
    }
    eng.setPan(Float(pan))
    DispatchQueue.main.async { result(nil) }
```

**Step 3: iOS build**

Run: `flutter build ios --no-codesign 2>&1 | tail -5`
Expected: `✓ Built build/ios/iphoneos/Runner.app`

**Step 4: Commit**

```bash
git add ios/Classes/LoopAudioEngine.swift ios/Classes/FlutterGaplessLoopPlugin.swift
git commit -m "feat(ios): add setPan using AVAudioMixerNode.pan"
```

---

### Task 4: Example app — BPM controls + panning slider

**Files:**
- Modify: `example/lib/main.dart`

Pure UI changes. No unit tests (UI-only state logic).

The current state class fields end at line 43 (`BpmResult? _bpmResult;`). Subscriptions at lines 46–49. `initState` at 52–57. `dispose` at 60–67. `_pickFile` at 99–119.

**Step 1: Add new state fields after `_volume = 1.0` (after line 42)**

```dart
double _pan = 0.0;

// BPM controls
double _manualBpm = 0.0;
final _bpmController = TextEditingController();
final List<DateTime> _tapTimes = [];
Timer? _bpmRepeatTimer;
```

**Step 2: Update the `_bpmSub` line in `initState` to auto-populate `_manualBpm`**

Replace (line 56):
```dart
_bpmSub   = _player.bpmStream.listen((r) => setState(() => _bpmResult = r));
```
With:
```dart
_bpmSub = _player.bpmStream.listen((r) {
  setState(() {
    _bpmResult = r;
    if (r.bpm > 0) {
      _manualBpm = r.bpm;
      _bpmController.text = r.bpm.toStringAsFixed(1);
    }
  });
});
```

**Step 3: Update `dispose` to cancel `_bpmRepeatTimer` and dispose `_bpmController`**

Add before `_player.dispose()` (before line 65):
```dart
_bpmRepeatTimer?.cancel();
_bpmController.dispose();
```

**Step 4: Reset BPM state on new file load in `_pickFile`**

In the `setState` block inside `_pickFile` (after line 114 `_bpmResult = null;`), add:
```dart
_manualBpm = 0.0;
_bpmController.text = '';
_tapTimes.clear();
```

**Step 5: Add helper methods before `bool get _isReady`**

Insert before `bool get _isReady` (before line 173):

```dart
void _adjustBpm(double delta) {
  setState(() {
    _manualBpm = (_manualBpm + delta).clamp(20.0, 300.0);
    _bpmController.text = _manualBpm.toStringAsFixed(1);
  });
}

void _onTapTempo() {
  final now = DateTime.now();
  if (_tapTimes.isNotEmpty &&
      now.difference(_tapTimes.last).inMilliseconds > 3000) {
    _tapTimes.clear();
  }
  _tapTimes.add(now);
  if (_tapTimes.length > 8) _tapTimes.removeAt(0);
  if (_tapTimes.length >= 2) {
    final intervals = <double>[];
    for (int i = 1; i < _tapTimes.length; i++) {
      intervals.add(
          _tapTimes[i].difference(_tapTimes[i - 1]).inMilliseconds / 1000.0);
    }
    final avg = intervals.reduce((a, b) => a + b) / intervals.length;
    setState(() {
      _manualBpm = (60.0 / avg).clamp(20.0, 300.0);
      _bpmController.text = _manualBpm.toStringAsFixed(1);
    });
  }
}

void _snapToBeat() {
  if (_manualBpm <= 0 || !_isReady) return;
  final beatPeriod = 60.0 / _manualBpm;
  var newStart = (_loopStart / beatPeriod).round() * beatPeriod;
  var newEnd   = (_loopEnd   / beatPeriod).round() * beatPeriod;
  newStart = newStart.clamp(0.0, _duration);
  newEnd   = newEnd.clamp(0.0, _duration);
  if (newStart >= newEnd) return;
  setState(() {
    _loopStart = newStart;
    _loopEnd   = newEnd;
  });
  _setLoopRegion();
}

Future<void> _setPan(double value) async {
  setState(() => _pan = value);
  try {
    await _player.setPan(value);
  } catch (e) {
    _onError(e.toString());
  }
}
```

**Step 6: Add BPM Controls + Panning sections to `build()`**

After the `_BpmCard` widget (after line 374 `_BpmCard(result: _bpmResult, isReady: _isReady),`), add:

```dart
const Divider(),

// ── BPM Controls ──────────────────────────────────────────
Text('BPM Controls', style: Theme.of(context).textTheme.titleSmall),
const SizedBox(height: 8),
Row(
  children: [
    // Decrement button with long-press repeat
    GestureDetector(
      onLongPressStart: (_) {
        _bpmRepeatTimer = Timer(const Duration(milliseconds: 400), () {
          _bpmRepeatTimer = Timer.periodic(
              const Duration(milliseconds: 100), (_) => _adjustBpm(-1.0));
        });
      },
      onLongPressEnd: (_) {
        _bpmRepeatTimer?.cancel();
        _bpmRepeatTimer = null;
      },
      child: IconButton(
        icon: const Icon(Icons.remove),
        onPressed: _isReady ? () => _adjustBpm(-1.0) : null,
      ),
    ),
    // Manual BPM text field
    Expanded(
      child: TextField(
        controller: _bpmController,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(
          labelText: 'BPM',
          isDense: true,
          border: OutlineInputBorder(),
        ),
        enabled: _isReady,
        onSubmitted: (v) {
          final parsed = double.tryParse(v);
          if (parsed != null) {
            setState(() {
              _manualBpm = parsed.clamp(20.0, 300.0);
              _bpmController.text = _manualBpm.toStringAsFixed(1);
            });
          }
        },
      ),
    ),
    // Increment button with long-press repeat
    GestureDetector(
      onLongPressStart: (_) {
        _bpmRepeatTimer = Timer(const Duration(milliseconds: 400), () {
          _bpmRepeatTimer = Timer.periodic(
              const Duration(milliseconds: 100), (_) => _adjustBpm(1.0));
        });
      },
      onLongPressEnd: (_) {
        _bpmRepeatTimer?.cancel();
        _bpmRepeatTimer = null;
      },
      child: IconButton(
        icon: const Icon(Icons.add),
        onPressed: _isReady ? () => _adjustBpm(1.0) : null,
      ),
    ),
  ],
),
const SizedBox(height: 8),
Row(
  children: [
    ElevatedButton.icon(
      onPressed: _isReady ? _onTapTempo : null,
      icon: const Icon(Icons.touch_app),
      label: const Text('Tap Tempo'),
    ),
    const SizedBox(width: 8),
    ElevatedButton.icon(
      onPressed: _isReady && _manualBpm > 0 ? _snapToBeat : null,
      icon: const Icon(Icons.grid_on),
      label: const Text('Snap to Beat'),
    ),
  ],
),

const Divider(),

// ── Panning ────────────────────────────────────────────────
Text('Panning', style: Theme.of(context).textTheme.titleSmall),
Row(
  children: [
    const SizedBox(width: 24, child: Text('L', textAlign: TextAlign.center)),
    Expanded(
      child: Slider(
        value: _pan,
        min: -1.0,
        max: 1.0,
        divisions: 200,
        onChanged: _isReady ? _setPan : null,
      ),
    ),
    const SizedBox(width: 24, child: Text('R', textAlign: TextAlign.center)),
  ],
),
Row(
  mainAxisAlignment: MainAxisAlignment.center,
  children: [
    Text(
      _pan == 0.0
          ? 'Centre'
          : _pan < 0
              ? 'L ${(-_pan * 100).toStringAsFixed(0)}%'
              : 'R ${(_pan * 100).toStringAsFixed(0)}%',
      style: Theme.of(context).textTheme.bodySmall,
    ),
  ],
),
```

**Step 7: Run flutter analyze on example**

Run: `flutter analyze example/ 2>&1 | tail -10`
Expected: `No issues found!`

**Step 8: Commit**

```bash
git add example/lib/main.dart
git commit -m "feat(example): add BPM controls (manual, ±1, tap tempo, snap-to-beat) and panning slider"
```

---

### Task 5: Final Verification

**Step 1: Full project analysis**

Run: `flutter analyze 2>&1 | tail -10`
Expected: `No issues found!`

**Step 2: Android unit tests**

Run: `cd android && ./gradlew test 2>&1 | tail -20`
Expected: 26 tests, all PASS

**Step 3: Android build**

Run: `flutter build apk --debug 2>&1 | tail -5`
Expected: `✓ Built build/app/outputs/flutter-apk/app-debug.apk`

**Step 4: iOS build**

Run: `flutter build ios --no-codesign 2>&1 | tail -5`
Expected: `✓ Built build/ios/iphoneos/Runner.app`

**Step 5: Review commit log**

Run: `git log --oneline -6`
Expected: 4 new commits (Tasks 1–4) on top of the BPM detection commits.
