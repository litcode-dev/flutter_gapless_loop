# Time Signature Detection Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add `beatsPerBar` (int) and `bars` (bar start timestamps in seconds) to `BpmResult` by extending the existing BPM detector with bar-level autocorrelation (Stage 4).

**Architecture:** `detectMeter()` is a private helper added to `BpmDetector` on both platforms. It reuses the already-normalised onset envelope and the beat period computed during Stage 2, evaluating autocorrelation at lags of 2×, 3×, 4×, 6×, 7× beat periods with a Gaussian prior favouring m=4. Bar timestamps are derived by stepping through beat timestamps at `beatsPerBar` intervals from the strongest-onset downbeat. Result fields are added to the existing `bpmDetected` event map — no new channels or streams.

**Tech Stack:** Swift (iOS), Kotlin (Android), Dart (Flutter); existing Android JUnit test target at `example/android`; method + event channel unchanged.

---

### Task 1: Android — write failing meter-detection tests

**Files:**
- Modify: `android/src/test/kotlin/com/fluttergaplessloop/FlutterGaplessLoopPluginTest.kt`

**Step 1: Add `MeterDetectorTest` class with helper and four test cases**

Append this class to the end of `FlutterGaplessLoopPluginTest.kt`:

```kotlin
class MeterDetectorTest {

    /**
     * Generates a mono float array with 10ms-wide amplitude pulses spaced at the beat period.
     * Beat 0 of each bar has amplitude 1.0; all other beats have amplitude 0.5.
     * This accent pattern gives the onset autocorrelation enough signal to distinguish
     * 3/4 from 4/4.
     */
    private fun pulseAtMeter(
        bpm: Double,
        beatsPerBar: Int,
        sampleRate: Int = 44100,
        durationSecs: Double = 16.0
    ): FloatArray {
        val n = (sampleRate * durationSecs).toInt()
        val pcm = FloatArray(n)
        val periodSamples = (sampleRate * 60.0 / bpm).toInt()
        val pulseLen = (sampleRate * 0.01).toInt() // 10 ms
        var pos = 0
        var beat = 0
        while (pos < n) {
            val amp = if (beat % beatsPerBar == 0) 1.0f else 0.5f
            val end = minOf(pos + pulseLen, n)
            for (i in pos until end) pcm[i] = amp
            pos += periodSamples
            beat++
        }
        return pcm
    }

    @Test
    fun `beatsPerBar is zero for silence`() {
        val pcm = FloatArray(44100 * 5) { 0f }
        val result = BpmDetector.detect(pcm, 44100, 1)
        assertEquals(0, result.beatsPerBar)
        assertTrue(result.bars.isEmpty())
    }

    @Test
    fun `beatsPerBar is zero for audio shorter than 2 seconds`() {
        val pcm = FloatArray(44100) { 0.5f }
        val result = BpmDetector.detect(pcm, 44100, 1)
        assertEquals(0, result.beatsPerBar)
        assertTrue(result.bars.isEmpty())
    }

    @Test
    fun `beatsPerBar is 4 for accented 4-4 click track`() {
        val pcm = pulseAtMeter(120.0, 4)
        val result = BpmDetector.detect(pcm, 44100, 1)
        assertEquals(4, result.beatsPerBar)
    }

    @Test
    fun `beatsPerBar is 3 for accented 3-4 waltz click track`() {
        val pcm = pulseAtMeter(120.0, 3)
        val result = BpmDetector.detect(pcm, 44100, 1)
        assertEquals(3, result.beatsPerBar)
    }

    @Test
    fun `bars list is monotonically increasing`() {
        val pcm = pulseAtMeter(120.0, 4)
        val result = BpmDetector.detect(pcm, 44100, 1)
        assertTrue(result.bars.size >= 2, "Expected at least 2 bars")
        for (i in 1 until result.bars.size) {
            assertTrue(
                result.bars[i] > result.bars[i - 1],
                "Non-monotonic: bars[$i]=${result.bars[i]} <= bars[${i-1}]=${result.bars[i-1]}"
            )
        }
    }
}
```

**Step 2: Run tests to verify they fail to compile**

```bash
cd /path/to/flutter_gapless_loop/example/android
./gradlew :flutter_gapless_loop:test 2>&1 | grep -E "error:|Unresolved"
```

Expected: compilation error — `beatsPerBar` and `bars` not found on `BpmDetectionResult`.

**Step 3: Commit the failing tests**

```bash
git add android/src/test/kotlin/com/fluttergaplessloop/FlutterGaplessLoopPluginTest.kt
git commit -m "test(android): add failing MeterDetectorTest cases"
```

---

### Task 2: Android — add fields to `BpmDetectionResult`

**Files:**
- Modify: `android/src/main/kotlin/com/fluttergaplessloop/BpmDetector.kt` (lines 22–26)

**Step 1: Add two fields with default values to the data class**

Change:
```kotlin
data class BpmDetectionResult(
    val bpm: Double,          // 0.0 if detection failed/skipped
    val confidence: Double,   // [0.0, 1.0]
    val beats: List<Double>   // timestamps in seconds
)
```

To:
```kotlin
data class BpmDetectionResult(
    val bpm: Double,          // 0.0 if detection failed/skipped
    val confidence: Double,   // [0.0, 1.0]
    val beats: List<Double>,  // beat timestamps in seconds
    val beatsPerBar: Int = 0,           // 0 = unknown (low confidence or too short)
    val bars: List<Double> = emptyList() // bar start timestamps in seconds
)
```

Default values keep all existing call-sites that construct `BpmDetectionResult` without the new fields compiling unchanged.

**Step 2: Run tests — expect compilation to pass, meter tests to fail on values**

```bash
cd /path/to/flutter_gapless_loop/example/android
./gradlew :flutter_gapless_loop:test 2>&1 | grep -E "PASSED|FAILED"
```

Expected: all existing tests PASSED; new `MeterDetectorTest` tests FAILED (values are 0 / empty because `detectMeter` not yet implemented).

**Step 3: Commit**

```bash
git add android/src/main/kotlin/com/fluttergaplessloop/BpmDetector.kt
git commit -m "feat(android): add beatsPerBar and bars fields to BpmDetectionResult"
```

---

### Task 3: Android — implement `detectMeter` in `BpmDetector.kt`

**Files:**
- Modify: `android/src/main/kotlin/com/fluttergaplessloop/BpmDetector.kt`

**Step 1: Add `detectMeter` private function and wire it into `detect()`**

In `BpmDetector.detect()`, replace the final `return` statement:

```kotlin
        return BpmDetectionResult(estimatedBpm, confidence, beats)
```

With:

```kotlin
        val (beatsPerBar, bars) = if (confidence >= 0.3) {
            detectMeter(onset, period, beats, sampleRate)
        } else {
            Pair(0, emptyList())
        }

        return BpmDetectionResult(estimatedBpm, confidence, beats, beatsPerBar, bars)
```

Then add `detectMeter` as a new private function inside `internal object BpmDetector { ... }`, after `trackBeats`:

```kotlin
    /**
     * Infers meter (beats per bar) from the onset envelope using bar-level autocorrelation.
     *
     * Evaluates onset autocorrelation at lags of 2, 3, 4, 6, and 7 beat periods, weighted
     * by a Gaussian prior favouring m=4 (σ=1.5). The candidate with the highest weighted
     * score wins. Bar timestamps are derived by stepping through [beats] at [beatsPerBar]
     * intervals from the beat with the strongest onset (the downbeat).
     *
     * Returns beatsPerBar=0 and empty bars if detection is not possible.
     */
    private fun detectMeter(
        onset: FloatArray,
        beatPeriod: Int,
        beats: List<Double>,
        sampleRate: Int
    ): Pair<Int, List<Double>> {
        val candidates   = intArrayOf(2, 3, 4, 6, 7)
        val priorMean    = 4.0
        val priorSigma   = 1.5
        val n            = onset.size

        var bestMeter = 0
        var bestScore = -Double.MAX_VALUE

        for (m in candidates) {
            val lag = m * beatPeriod
            if (lag >= n) continue
            val count = n - lag
            var sum = 0.0
            for (t in 0 until count) sum += onset[t].toDouble() * onset[t + lag].toDouble()
            val ac = sum / count
            val z = (m.toDouble() - priorMean) / priorSigma
            val weighted = ac * exp(-0.5 * z * z)
            if (weighted > bestScore) { bestScore = weighted; bestMeter = m }
        }

        if (bestMeter == 0 || beats.size < bestMeter) return Pair(0, emptyList())

        // Find the beat with the strongest onset value → use as downbeat anchor
        var strongestIdx = 0
        var strongestStrength = 0f
        for (i in beats.indices) {
            val frame = (beats[i] * sampleRate / HOP_SIZE).toInt().coerceIn(0, n - 1)
            if (onset[frame] > strongestStrength) {
                strongestStrength = onset[frame]
                strongestIdx = i
            }
        }

        // Step forward and backward from strongestIdx by bestMeter to collect bar starts
        val barIndices = mutableListOf<Int>()
        var idx = strongestIdx
        while (idx < beats.size) { barIndices.add(idx); idx += bestMeter }
        idx = strongestIdx - bestMeter
        while (idx >= 0) { barIndices.add(0, idx); idx -= bestMeter }

        return Pair(bestMeter, barIndices.map { beats[it] })
    }
```

**Step 2: Run tests and verify all pass**

```bash
cd /path/to/flutter_gapless_loop/example/android
./gradlew :flutter_gapless_loop:test 2>&1 | grep -E "PASSED|FAILED|tests were"
```

Expected: all 31 tests PASSED (26 existing + 5 new).

**Step 3: Commit**

```bash
git add android/src/main/kotlin/com/fluttergaplessloop/BpmDetector.kt
git commit -m "feat(android): implement detectMeter via bar-level onset autocorrelation"
```

---

### Task 4: Android — add `beatsPerBar` and `bars` to plugin event map

**Files:**
- Modify: `android/src/main/kotlin/com/fluttergaplessloop/FlutterGaplessLoopPlugin.kt` (lines 246–253)

**Step 1: Extend the `onBpmDetected` callback event map**

Find `wireEngineCallbacks` and replace:

```kotlin
        eng.onBpmDetected = { bpmResult ->
            sendEvent(mapOf(
                "type"       to "bpmDetected",
                "bpm"        to bpmResult.bpm,
                "confidence" to bpmResult.confidence,
                "beats"      to bpmResult.beats
            ))
        }
```

With:

```kotlin
        eng.onBpmDetected = { bpmResult ->
            sendEvent(mapOf(
                "type"        to "bpmDetected",
                "bpm"         to bpmResult.bpm,
                "confidence"  to bpmResult.confidence,
                "beats"       to bpmResult.beats,
                "beatsPerBar" to bpmResult.beatsPerBar,
                "bars"        to bpmResult.bars
            ))
        }
```

**Step 2: Run tests to confirm nothing regressed**

```bash
cd /path/to/flutter_gapless_loop/example/android
./gradlew :flutter_gapless_loop:test 2>&1 | grep -E "PASSED|FAILED|BUILD"
```

Expected: BUILD SUCCESSFUL, all 31 tests PASSED.

**Step 3: Commit**

```bash
git add android/src/main/kotlin/com/fluttergaplessloop/FlutterGaplessLoopPlugin.kt
git commit -m "feat(android): emit beatsPerBar and bars in bpmDetected event"
```

---

### Task 5: iOS — extend `BpmResult` and implement `detectMeter`

**Files:**
- Modify: `ios/Classes/BpmDetector.swift`

No iOS unit test infrastructure exists for `BpmDetector`. Verification is done by building the example app (Task 7).

**Step 1: Add fields to `BpmResult` struct**

Find and replace the struct definition (lines 8–15):

```swift
public struct BpmResult {
    /// Estimated tempo in beats per minute. `0.0` if detection failed or was skipped.
    public let bpm: Double
    /// Confidence in [0.0, 1.0]. Values above 0.5 indicate reliable detection.
    public let confidence: Double
    /// Beat timestamps in seconds from the start of the file.
    public let beats: [Double]
}
```

With:

```swift
public struct BpmResult {
    /// Estimated tempo in beats per minute. `0.0` if detection failed or was skipped.
    public let bpm: Double
    /// Confidence in [0.0, 1.0]. Values above 0.5 indicate reliable detection.
    public let confidence: Double
    /// Beat timestamps in seconds from the start of the file.
    public let beats: [Double]
    /// Estimated beats per bar (time signature numerator). `0` if unknown (low confidence or
    /// audio too short). Typical values: 2, 3, 4, 6, 7.
    public let beatsPerBar: Int
    /// Bar start timestamps in seconds. Empty if `beatsPerBar` is 0.
    public let bars: [Double]
}
```

**Step 2: Update the two early-return `BpmResult` literals in `detect()`**

Both `return BpmResult(bpm: 0, confidence: 0, beats: [])` lines must gain the new fields. Replace each with:

```swift
return BpmResult(bpm: 0, confidence: 0, beats: [], beatsPerBar: 0, bars: [])
```

There are three such returns — search for `BpmResult(bpm: 0` and update all occurrences.

**Step 3: Update the final `return` in `detect()` to call `detectMeter`**

Find:

```swift
        return BpmResult(bpm: estimatedBpm, confidence: confidence, beats: beats)
```

Replace with:

```swift
        let (beatsPerBar, bars): (Int, [Double]) = confidence >= 0.3
            ? detectMeter(onset: onset, beatPeriod: period, beats: beats, sampleRate: sampleRate)
            : (0, [])

        return BpmResult(bpm: estimatedBpm, confidence: confidence, beats: beats,
                         beatsPerBar: beatsPerBar, bars: bars)
```

**Step 4: Add the `detectMeter` private static function**

Insert the following after the closing `}` of `trackBeats` and before the closing `}` of `BpmDetector`:

```swift
    /// Infers the meter (beats per bar) from the onset envelope using bar-level autocorrelation.
    ///
    /// Evaluates onset autocorrelation at lags of 2, 3, 4, 6, and 7 beat periods, weighted
    /// by a Gaussian prior favouring m=4 (σ=1.5). Bar timestamps are derived by stepping
    /// through `beats` at `beatsPerBar` intervals from the strongest-onset downbeat.
    ///
    /// - Returns: `(0, [])` if the audio is too short or meter is ambiguous.
    private static func detectMeter(
        onset: [Float], beatPeriod: Int, beats: [Double], sampleRate: Double
    ) -> (Int, [Double]) {
        let candidates  = [2, 3, 4, 6, 7]
        let priorMean   = 4.0
        let priorSigma  = 1.5
        let n           = onset.count

        var bestMeter = 0
        var bestScore = -Double.greatestFiniteMagnitude

        for m in candidates {
            let lag = m * beatPeriod
            guard lag < n else { continue }
            let count = n - lag
            var sum: Double = 0
            for t in 0 ..< count { sum += Double(onset[t]) * Double(onset[t + lag]) }
            let ac = sum / Double(count)
            let z  = (Double(m) - priorMean) / priorSigma
            let weighted = ac * exp(-0.5 * z * z)
            if weighted > bestScore { bestScore = weighted; bestMeter = m }
        }

        guard bestMeter > 0, beats.count >= bestMeter else { return (0, []) }

        // Find the beat with the strongest onset → use as downbeat anchor
        var strongestIdx = 0
        var strongestStrength: Float = 0
        for (i, ts) in beats.enumerated() {
            let frame = min(Int((ts * sampleRate / Double(hopSize)).rounded()), n - 1)
            if onset[frame] > strongestStrength {
                strongestStrength = onset[frame]
                strongestIdx = i
            }
        }

        // Step forward and backward by bestMeter to collect bar start indices
        var barIndices = [Int]()
        var idx = strongestIdx
        while idx < beats.count { barIndices.append(idx); idx += bestMeter }
        idx = strongestIdx - bestMeter
        while idx >= 0 { barIndices.insert(idx, at: 0); idx -= bestMeter }

        return (bestMeter, barIndices.map { beats[$0] })
    }
```

**Step 5: Commit**

```bash
git add ios/Classes/BpmDetector.swift
git commit -m "feat(ios): implement detectMeter and extend BpmResult with beatsPerBar/bars"
```

---

### Task 6: iOS — emit `beatsPerBar` and `bars` in plugin event map

**Files:**
- Modify: `ios/Classes/FlutterGaplessLoopPlugin.swift` (lines 84–95)

**Step 1: Extend the `onBpmDetected` closure**

Find:

```swift
        eng.onBpmDetected = { [weak self] bpmResult in
            DispatchQueue.main.async {
                self?.eventSink?([
                    "type":       "bpmDetected",
                    "bpm":        bpmResult.bpm,
                    "confidence": bpmResult.confidence,
                    "beats":      bpmResult.beats
                ])
            }
        }
```

Replace with:

```swift
        eng.onBpmDetected = { [weak self] bpmResult in
            DispatchQueue.main.async {
                self?.eventSink?([
                    "type":        "bpmDetected",
                    "bpm":         bpmResult.bpm,
                    "confidence":  bpmResult.confidence,
                    "beats":       bpmResult.beats,
                    "beatsPerBar": bpmResult.beatsPerBar,
                    "bars":        bpmResult.bars
                ])
            }
        }
```

**Step 2: Commit**

```bash
git add ios/Classes/FlutterGaplessLoopPlugin.swift
git commit -m "feat(ios): emit beatsPerBar and bars in bpmDetected event"
```

---

### Task 7: Dart — extend `BpmResult` and `fromMap`

**Files:**
- Modify: `lib/src/loop_audio_state.dart`

**Step 1: Add two fields to `BpmResult`**

Find the class definition (lines 49–75) and replace with:

```dart
/// The result of BPM/tempo detection on a loaded audio file.
///
/// Emitted via [LoopAudioPlayer.bpmStream] after every successful load.
class BpmResult {
  /// Estimated tempo in beats per minute. `0.0` if detection was skipped
  /// (audio shorter than 2 seconds or completely silent).
  final double bpm;

  /// Confidence of the estimate in [0.0, 1.0]. Values above 0.5 indicate
  /// reliable detection.
  final double confidence;

  /// Beat timestamps in seconds from the start of the file.
  final List<double> beats;

  /// Estimated beats per bar (time signature numerator). `0` if unknown
  /// (low confidence or audio too short). Typical values: 2, 3, 4, 6, 7.
  final int beatsPerBar;

  /// Bar start timestamps in seconds. Empty if [beatsPerBar] is `0`.
  final List<double> bars;

  const BpmResult({
    required this.bpm,
    required this.confidence,
    required this.beats,
    this.beatsPerBar = 0,
    this.bars = const [],
  });

  /// Creates a [BpmResult] from the raw map sent by the native event channel.
  factory BpmResult.fromMap(Map<Object?, Object?> map) => BpmResult(
    bpm:         (map['bpm'] as num? ?? 0).toDouble(),
    confidence:  (map['confidence'] as num? ?? 0).toDouble(),
    beats: ((map['beats'] as List<Object?>?) ?? const [])
        .map((e) => (e as num).toDouble())
        .toList(),
    beatsPerBar: (map['beatsPerBar'] as int? ?? 0),
    bars: ((map['bars'] as List<Object?>?) ?? const [])
        .map((e) => (e as num).toDouble())
        .toList(),
  );
}
```

**Step 2: Verify the Dart package analyzes cleanly**

```bash
cd /path/to/flutter_gapless_loop
flutter analyze lib/
```

Expected: No issues found.

**Step 3: Commit**

```bash
git add lib/src/loop_audio_state.dart
git commit -m "feat(dart): add beatsPerBar and bars to BpmResult"
```

---

### Task 8: Build verification

**Step 1: Build the example app for iOS**

```bash
cd /path/to/flutter_gapless_loop/example
flutter build ios --no-codesign 2>&1 | tail -5
```

Expected: `Build complete.` (or `Archive Succeeded`).

**Step 2: Run Android unit tests one final time**

```bash
cd /path/to/flutter_gapless_loop/example/android
./gradlew :flutter_gapless_loop:test 2>&1 | grep -E "BUILD|tests were"
```

Expected: `BUILD SUCCESSFUL`, all 31 tests passed.

**Step 3: Final commit (if any cleanup needed)**

```bash
git add -p   # review any remaining changes
git commit -m "chore: post-implementation cleanup"
```

---

## Summary of Changes

| File | Change |
|------|--------|
| `android/src/main/kotlin/.../BpmDetector.kt` | Add `beatsPerBar`/`bars` to `BpmDetectionResult`; add `detectMeter()` helper; call it from `detect()` |
| `android/src/main/kotlin/.../FlutterGaplessLoopPlugin.kt` | Add `beatsPerBar`/`bars` to `bpmDetected` event map |
| `android/src/test/kotlin/.../FlutterGaplessLoopPluginTest.kt` | Add `MeterDetectorTest` with 5 test cases |
| `ios/Classes/BpmDetector.swift` | Add `beatsPerBar`/`bars` to `BpmResult`; add `detectMeter()` helper; call it from `detect()` |
| `ios/Classes/FlutterGaplessLoopPlugin.swift` | Add `beatsPerBar`/`bars` to `bpmDetected` event map |
| `lib/src/loop_audio_state.dart` | Add `beatsPerBar`/`bars` fields to `BpmResult` and `fromMap` |
