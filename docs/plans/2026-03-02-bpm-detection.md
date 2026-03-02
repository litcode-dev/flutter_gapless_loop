# BPM/Tempo Detection — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Add automatic BPM/Tempo detection to `flutter_gapless_loop` on both iOS and Android using the Ellis (2007) energy onset beat tracking algorithm — no external libraries.

**Architecture:** After every successful load, the native engine launches BPM detection on a background thread. The full decoded PCM buffer (already in memory) is analysed in three stages: onset strength envelope → weighted autocorrelation → dynamic programming beat sequence. When complete, a `bpmDetected` event is pushed through the existing event channel to Dart.

**Tech Stack:** Pure Swift (iOS), pure Kotlin (Android), `DispatchWorkItem` / coroutine `Job` for cancellation, `AVAudioPCMBuffer` (iOS) / `FloatArray` (Android), Dart `EventChannel` stream.

---

## Pre-work: Read These Files Before Each Task

- Design doc: `docs/plans/2026-03-02-bpm-detection-design.md`
- iOS engine: `ios/Classes/LoopAudioEngine.swift`
- iOS plugin: `ios/Classes/FlutterGaplessLoopPlugin.swift`
- Android engine: `android/src/main/kotlin/com/fluttergaplessloop/LoopAudioEngine.kt`
- Android plugin: `android/src/main/kotlin/com/fluttergaplessloop/FlutterGaplessLoopPlugin.kt`
- Dart player: `lib/src/loop_audio_player.dart`
- Dart state: `lib/src/loop_audio_state.dart`

Channel name: `"flutter_gapless_loop"` | Event channel: `"flutter_gapless_loop/events"`

Event payload the new feature adds:
```json
{"type": "bpmDetected", "bpm": 128.0, "confidence": 0.94, "beats": [0.23, 0.70, 1.17]}
```

---

### Task 1: Dart — BpmResult class + bpmStream

**Files:**
- Modify: `lib/src/loop_audio_state.dart`
- Modify: `lib/src/loop_audio_player.dart`
- Modify: `test/flutter_gapless_loop_test.dart`

**Step 1: Write failing Dart tests**

Add to `test/flutter_gapless_loop_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gapless_loop/flutter_gapless_loop.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('LoopAudioPlayer can be instantiated', () {
    final player = LoopAudioPlayer();
    expect(player, isNotNull);
  });

  test('PlayerState enum has expected values', () {
    expect(PlayerState.values, containsAll([
      PlayerState.idle, PlayerState.loading, PlayerState.ready,
      PlayerState.playing, PlayerState.paused, PlayerState.stopped,
      PlayerState.error,
    ]));
  });

  group('BpmResult', () {
    test('fromMap parses bpm, confidence, and beats correctly', () {
      final result = BpmResult.fromMap({
        'bpm': 128.0,
        'confidence': 0.92,
        'beats': [0.23, 0.70, 1.17],
      });
      expect(result.bpm, closeTo(128.0, 0.001));
      expect(result.confidence, closeTo(0.92, 0.001));
      expect(result.beats, [0.23, 0.70, 1.17]);
    });

    test('fromMap handles integer bpm value', () {
      final result = BpmResult.fromMap({
        'bpm': 120,
        'confidence': 0.85,
        'beats': <Object?>[],
      });
      expect(result.bpm, 120.0);
    });

    test('fromMap handles empty beats list', () {
      final result = BpmResult.fromMap({
        'bpm': 0.0,
        'confidence': 0.0,
        'beats': <Object?>[],
      });
      expect(result.beats, isEmpty);
    });
  });
}
```

**Step 2: Run test to verify it fails**

```bash
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop
flutter test test/flutter_gapless_loop_test.dart
```

Expected: FAIL — `BpmResult` not defined.

**Step 3: Add BpmResult to loop_audio_state.dart**

Append to the END of `lib/src/loop_audio_state.dart`:

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

  const BpmResult({
    required this.bpm,
    required this.confidence,
    required this.beats,
  });

  /// Creates a [BpmResult] from the raw map sent by the native event channel.
  factory BpmResult.fromMap(Map<Object?, Object?> map) => BpmResult(
    bpm:        (map['bpm'] as num).toDouble(),
    confidence: (map['confidence'] as num).toDouble(),
    beats: (map['beats'] as List<Object?>)
        .map((e) => (e as num).toDouble())
        .toList(),
  );
}
```

**Step 4: Add bpmStream to loop_audio_player.dart**

Add this getter after `routeChangeStream` in `lib/src/loop_audio_player.dart`:

```dart
  /// Stream of [BpmResult] emitted automatically after each successful load.
  ///
  /// Fires once per load, shortly after [stateStream] emits [PlayerState.ready],
  /// when the background beat-tracking analysis completes.
  ///
  /// Returns `bpm: 0.0` if the audio is shorter than 2 seconds or silent.
  Stream<BpmResult> get bpmStream {
    _checkNotDisposed();
    return _events
        .where((e) => e['type'] == 'bpmDetected')
        .map((e) => BpmResult.fromMap(e));
  }
```

**Step 5: Run tests to verify they pass**

```bash
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop
flutter test test/flutter_gapless_loop_test.dart
```

Expected: All tests PASS.

**Step 6: Run flutter analyze**

```bash
flutter analyze
```

Expected: `No issues found!`

**Step 7: Commit**

```bash
git add lib/src/loop_audio_state.dart lib/src/loop_audio_player.dart test/flutter_gapless_loop_test.dart
git commit -m "feat(dart): add BpmResult type and bpmStream to LoopAudioPlayer"
```

---

### Task 2: Android — BpmDetector.kt (TDD)

**Files:**
- Modify: `android/src/test/kotlin/com/fluttergaplessloop/FlutterGaplessLoopPluginTest.kt`
- Create: `android/src/main/kotlin/com/fluttergaplessloop/BpmDetector.kt`

**Step 1: Write failing tests**

Add `BpmDetectorTest` class to the END of `android/src/test/kotlin/com/fluttergaplessloop/FlutterGaplessLoopPluginTest.kt`:

```kotlin
class BpmDetectorTest {

    // ─── Helpers ──────────────────────────────────────────────────────────────

    /** Generates a mono float array with 10ms-wide amplitude pulses at every beat. */
    private fun pulseAt(bpm: Double, sampleRate: Int = 44100, durationSecs: Double = 10.0): FloatArray {
        val n = (sampleRate * durationSecs).toInt()
        val pcm = FloatArray(n)
        val periodSamples = (sampleRate * 60.0 / bpm).toInt()
        val pulseLen = (sampleRate * 0.01).toInt() // 10ms pulse
        var pos = 0
        while (pos < n) {
            val end = minOf(pos + pulseLen, n)
            for (i in pos until end) pcm[i] = 1.0f
            pos += periodSamples
        }
        return pcm
    }

    // ─── Tests ────────────────────────────────────────────────────────────────

    @Test
    fun `detect returns zero result for audio shorter than 2 seconds`() {
        val pcm = FloatArray(44100) { 0.5f }   // 1 second
        val result = BpmDetector.detect(pcm, 44100, 1)
        assertEquals(0.0, result.bpm, 0.001)
        assertEquals(0.0, result.confidence, 0.001)
        assertTrue(result.beats.isEmpty())
    }

    @Test
    fun `detect returns zero result for silence`() {
        val pcm = FloatArray(44100 * 5) { 0f }  // 5 seconds of silence
        val result = BpmDetector.detect(pcm, 44100, 1)
        assertEquals(0.0, result.bpm, 0.001)
        assertTrue(result.beats.isEmpty())
    }

    @Test
    fun `detect 120 BPM pulse train within 2 BPM tolerance`() {
        val pcm = pulseAt(120.0)
        val result = BpmDetector.detect(pcm, 44100, 1)
        assertTrue(
            abs(result.bpm - 120.0) <= 2.0,
            "Expected ~120 BPM, got ${result.bpm}"
        )
        assertTrue(result.confidence > 0.5, "Expected confidence > 0.5, got ${result.confidence}")
    }

    @Test
    fun `detect 128 BPM pulse train within 2 BPM tolerance`() {
        val pcm = pulseAt(128.0)
        val result = BpmDetector.detect(pcm, 44100, 1)
        assertTrue(
            abs(result.bpm - 128.0) <= 2.0,
            "Expected ~128 BPM, got ${result.bpm}"
        )
    }

    @Test
    fun `stereo audio produces same BPM as mono`() {
        val mono = pulseAt(120.0)
        // Interleave into stereo: [L0, R0, L1, R1, ...]
        val stereo = FloatArray(mono.size * 2) { i -> mono[i / 2] }
        val monoResult   = BpmDetector.detect(mono, 44100, 1)
        val stereoResult = BpmDetector.detect(stereo, 44100, 2)
        assertEquals(monoResult.bpm, stereoResult.bpm, 0.001)
    }

    @Test
    fun `beat timestamps are monotonically increasing`() {
        val pcm = pulseAt(120.0)
        val result = BpmDetector.detect(pcm, 44100, 1)
        assertTrue(result.beats.size >= 2)
        for (i in 1 until result.beats.size) {
            assertTrue(result.beats[i] > result.beats[i - 1],
                "Non-monotonic: beats[$i]=${result.beats[i]} <= beats[${i-1}]=${result.beats[i-1]}")
        }
    }

    @Test
    fun `no beats in micro-fade region (first 5ms)`() {
        val pcm = pulseAt(120.0)
        val result = BpmDetector.detect(pcm, 44100, 1)
        assertTrue(result.beats.all { it >= 0.005 },
            "Found beat before 5ms: ${result.beats.filter { it < 0.005 }}")
    }

    @Test
    fun `confidence is in range 0 to 1`() {
        val pcm = pulseAt(120.0)
        val result = BpmDetector.detect(pcm, 44100, 1)
        assertTrue(result.confidence in 0.0..1.0,
            "Confidence out of range: ${result.confidence}")
    }
}
```

**Step 2: Run to verify tests fail**

```bash
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop/example/android
./gradlew :flutter_gapless_loop:testDebugUnitTest 2>&1 | tail -20
```

Expected: FAIL — `BpmDetector` not found.

**Step 3: Create BpmDetector.kt**

Create `android/src/main/kotlin/com/fluttergaplessloop/BpmDetector.kt`:

```kotlin
package com.fluttergaplessloop

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.round
import kotlin.math.sqrt

/**
 * BPM/Tempo detector using the Ellis (2007) energy onset beat tracking algorithm.
 *
 * No Android framework dependencies — pure Kotlin, fully thread-safe (no shared state).
 *
 * Algorithm:
 *  1. Mix stereo to mono; compute RMS energy per 512-sample frame (256-sample hop).
 *  2. Positive half-wave rectified energy derivative → onset strength envelope.
 *  3. Weighted autocorrelation (Gaussian prior at 120 BPM) → BPM estimate.
 *  4. Dynamic programming forward pass → globally consistent beat sequence.
 */
internal object BpmDetector {

    private const val FRAME_SIZE          = 512
    private const val HOP_SIZE            = 256
    private const val MIN_BPM             = 60.0
    private const val MAX_BPM             = 180.0
    private const val TEMPO_PRIOR_MEAN    = 120.0
    private const val TEMPO_PRIOR_SIGMA   = 30.0
    private const val DP_LAMBDA           = 100.0
    private const val MIN_DURATION_SECS   = 2.0

    /** Output of BPM detection. */
    data class BpmResult(
        val bpm: Double,          // 0.0 if detection failed/skipped
        val confidence: Double,   // [0.0, 1.0]
        val beats: List<Double>   // timestamps in seconds
    )

    /**
     * Detects BPM and beat timestamps from decoded PCM audio.
     *
     * @param pcm         Interleaved float samples, range [-1.0, 1.0].
     * @param sampleRate  Sample rate in Hz (e.g. 44100, 48000).
     * @param channelCount 1 (mono) or 2 (stereo).
     * @return [BpmResult] with bpm=0.0 and empty beats if audio is too short or silent.
     */
    fun detect(pcm: FloatArray, sampleRate: Int, channelCount: Int): BpmResult {
        val totalFrames     = pcm.size / channelCount
        val durationSeconds = totalFrames.toDouble() / sampleRate

        if (durationSeconds < MIN_DURATION_SECS) {
            return BpmResult(0.0, 0.0, emptyList())
        }

        // Stage 1: Onset strength envelope
        val mono  = mixToMono(pcm, channelCount)
        val onset = computeOnsetStrength(mono)

        val maxOnset = onset.maxOrNull() ?: 0f
        if (maxOnset == 0f) return BpmResult(0.0, 0.0, emptyList())
        for (i in onset.indices) onset[i] /= maxOnset   // normalize to [0, 1]

        // Stage 2: BPM estimation via weighted autocorrelation
        val lagMin = (sampleRate.toDouble() / (MAX_BPM / 60.0) / HOP_SIZE).toInt().coerceAtLeast(1)
        val lagMax = (sampleRate.toDouble() / (MIN_BPM / 60.0) / HOP_SIZE).toInt()
            .coerceAtMost(onset.size / 2)

        if (lagMin >= lagMax) return BpmResult(0.0, 0.0, emptyList())

        val ac      = autocorrelate(onset, lagMin, lagMax, sampleRate)
        val bestIdx = ac.indices.maxByOrNull { ac[it] }
            ?: return BpmResult(0.0, 0.0, emptyList())
        val actualLag    = bestIdx + lagMin
        val estimatedBpm = 60.0 * sampleRate / (actualLag.toDouble() * HOP_SIZE)
        val confidence   = ac[bestIdx].toDouble().coerceIn(0.0, 1.0)

        // Stage 3: DP beat sequence
        val period = round(sampleRate.toDouble() / (estimatedBpm / 60.0) / HOP_SIZE).toInt()
        val beats  = trackBeats(onset, period, sampleRate)

        return BpmResult(estimatedBpm, confidence, beats)
    }

    // ─── Private Helpers ──────────────────────────────────────────────────────

    private fun mixToMono(pcm: FloatArray, channelCount: Int): FloatArray {
        if (channelCount == 1) return pcm.copyOf()
        val frames = pcm.size / channelCount
        return FloatArray(frames) { f ->
            var sum = 0f
            for (ch in 0 until channelCount) sum += pcm[f * channelCount + ch]
            sum / channelCount
        }
    }

    private fun computeOnsetStrength(mono: FloatArray): FloatArray {
        val nFrames = (mono.size - FRAME_SIZE) / HOP_SIZE + 1
        val rms = FloatArray(nFrames) { f ->
            val start = f * HOP_SIZE
            var sumSq = 0.0
            for (i in start until start + FRAME_SIZE) {
                val s = mono[i].toDouble()
                sumSq += s * s
            }
            sqrt(sumSq / FRAME_SIZE).toFloat()
        }
        // Positive half-wave rectified derivative
        val onset = FloatArray(nFrames)
        for (f in 1 until nFrames) onset[f] = max(0f, rms[f] - rms[f - 1])
        return onset
    }

    private fun autocorrelate(
        onset: FloatArray, lagMin: Int, lagMax: Int, sampleRate: Int
    ): FloatArray {
        val n    = onset.size
        val nLags = lagMax - lagMin + 1
        val ac   = FloatArray(nLags)

        for (i in 0 until nLags) {
            val lag   = lagMin + i
            val count = n - lag
            if (count <= 0) continue

            var sum = 0.0
            for (t in 0 until count) sum += onset[t].toDouble() * onset[t + lag].toDouble()
            val normalized = sum / count

            // Gaussian tempo prior: centre at 120 BPM, σ = 30 BPM
            val bpm    = 60.0 * sampleRate / (lag.toDouble() * HOP_SIZE)
            val z      = (bpm - TEMPO_PRIOR_MEAN) / TEMPO_PRIOR_SIGMA
            val weight = exp(-0.5 * z * z)
            ac[i] = (normalized * weight).toFloat()
        }

        // Normalize to [0, 1] so peak = confidence
        val maxAc = ac.maxOrNull() ?: return ac
        if (maxAc > 0f) for (i in ac.indices) ac[i] /= maxAc
        return ac
    }

    private fun trackBeats(onset: FloatArray, period: Int, sampleRate: Int): List<Double> {
        val n = onset.size
        if (period <= 0 || n < period) return emptyList()

        val score = FloatArray(n) { -Float.MAX_VALUE }
        val prev  = IntArray(n) { -1 }

        // Seed: first two periods may contain the first beat
        for (t in 0 until min(period * 2, n)) score[t] = onset[t]

        val halfPeriod = period / 2
        val twoPeriod  = period * 2
        for (t in period until n) {
            for (d in halfPeriod..twoPeriod) {
                val b = t - d
                if (b < 0 || score[b] == -Float.MAX_VALUE) continue
                val logRatio = ln(d.toDouble() / period)
                val penalty  = (DP_LAMBDA * logRatio * logRatio).toFloat()
                val candidate = score[b] + onset[t] - penalty
                if (candidate > score[t]) { score[t] = candidate; prev[t] = b }
            }
        }

        // Backtrack from best frame in last period
        var best = n - 1
        for (t in max(0, n - period) until n) if (score[t] > score[best]) best = t

        val beatFrames = mutableListOf<Int>()
        var t = best
        while (t >= 0 && score[t] > -Float.MAX_VALUE) {
            beatFrames.add(0, t)
            t = prev[t]
        }

        // Convert to seconds, drop micro-fade region (first 5ms)
        val microFadeSeconds = 0.005
        return beatFrames
            .map { f -> f.toDouble() * HOP_SIZE / sampleRate }
            .filter { ts -> ts >= microFadeSeconds }
    }
}
```

**Step 4: Run tests to verify they pass**

```bash
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop/example/android
./gradlew :flutter_gapless_loop:testDebugUnitTest 2>&1 | tail -25
```

Expected: All tests PASS including the 8 new BpmDetectorTest tests. Total should be 19 (11 existing + 8 new).

**Step 5: Commit**

```bash
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop
git add android/src/main/kotlin/com/fluttergaplessloop/BpmDetector.kt \
        android/src/test/kotlin/com/fluttergaplessloop/FlutterGaplessLoopPluginTest.kt
git commit -m "feat(android): add BpmDetector (Ellis 2007 energy onset beat tracker)"
```

---

### Task 3: Android — Wire BPM into LoopAudioEngine and FlutterGaplessLoopPlugin

**Files:**
- Modify: `android/src/main/kotlin/com/fluttergaplessloop/LoopAudioEngine.kt`
- Modify: `android/src/main/kotlin/com/fluttergaplessloop/FlutterGaplessLoopPlugin.kt`

**Step 1: Add callback + job + launchBpmDetection to LoopAudioEngine.kt**

Read `android/src/main/kotlin/com/fluttergaplessloop/LoopAudioEngine.kt` first.

Make these four targeted edits:

**Edit 1** — Add `onBpmDetected` callback after `onRouteChange` (which is around line 90, near the other `var on*` callbacks). Add:
```kotlin
    /** Invoked when BPM detection completes after a load. Always called on the main thread. */
    var onBpmDetected: ((BpmDetector.BpmResult) -> Unit)? = null
```

**Edit 2** — Add `bpmJob` property in the `// ─── Private: decoded audio` section (around line 115, near `pcmBuffer`):
```kotlin
    /** Coroutine job for background BPM detection. Cancelled on each new load and dispose(). */
    private var bpmJob: Job? = null
```

**Edit 3** — In `loadFile()`, add `bpmJob?.cancel()` as the FIRST line of the function body (before `setState(EngineState.Loading)`), and add `launchBpmDetection()` immediately after the `setState(EngineState.Ready)` line.

Before (in loadFile):
```kotlin
    suspend fun loadFile(path: String) {
        setState(EngineState.Loading)
        try {
            val decoded = AudioFileLoader.decode(path)
            AudioFileLoader.applyMicroFade(decoded.pcm, decoded.sampleRate, decoded.channelCount)
            commitDecodedAudio(decoded)
            setState(EngineState.Ready)
```

After:
```kotlin
    suspend fun loadFile(path: String) {
        bpmJob?.cancel()
        setState(EngineState.Loading)
        try {
            val decoded = AudioFileLoader.decode(path)
            AudioFileLoader.applyMicroFade(decoded.pcm, decoded.sampleRate, decoded.channelCount)
            commitDecodedAudio(decoded)
            setState(EngineState.Ready)
            launchBpmDetection()
```

**Edit 4** — Same pattern in `loadAsset()`:

Before:
```kotlin
    suspend fun loadAsset(assetKey: String, assetFd: android.content.res.AssetFileDescriptor) {
        setState(EngineState.Loading)
        try {
            val decoded = AudioFileLoader.decodeAsset(assetFd)
            AudioFileLoader.applyMicroFade(decoded.pcm, decoded.sampleRate, decoded.channelCount)
            commitDecodedAudio(decoded)
            setState(EngineState.Ready)
```

After:
```kotlin
    suspend fun loadAsset(assetKey: String, assetFd: android.content.res.AssetFileDescriptor) {
        bpmJob?.cancel()
        setState(EngineState.Loading)
        try {
            val decoded = AudioFileLoader.decodeAsset(assetFd)
            AudioFileLoader.applyMicroFade(decoded.pcm, decoded.sampleRate, decoded.channelCount)
            commitDecodedAudio(decoded)
            setState(EngineState.Ready)
            launchBpmDetection()
```

**Edit 5** — In `dispose()`, add `bpmJob?.cancel()` and `bpmJob = null` BEFORE `pcmBuffer = null`. Find the line `pcmBuffer = null` in dispose and add before it:
```kotlin
        bpmJob?.cancel()
        bpmJob = null
```

**Edit 6** — Add the private `launchBpmDetection()` method near the bottom of the class, before the closing `}` of the class, in the private helpers section:

```kotlin
    /**
     * Launches BPM detection on [Dispatchers.IO].
     * Captures the current [pcmBuffer], [sampleRate], and [channelCount] by value
     * so the write thread cannot cause a data race.
     * On completion, invokes [onBpmDetected] on the main thread.
     */
    private fun launchBpmDetection() {
        val pcm = pcmBuffer ?: return
        val sr  = sampleRate
        val ch  = channelCount
        bpmJob = engineScope.launch(Dispatchers.IO) {
            val result = BpmDetector.detect(pcm, sr, ch)
            engineScope.launch {          // switches to Dispatchers.Main (scope default)
                onBpmDetected?.invoke(result)
            }
        }
    }
```

Also add `import kotlinx.coroutines.Dispatchers` if it isn't already imported (check the existing imports).

**Step 2: Wire onBpmDetected in FlutterGaplessLoopPlugin.kt**

In `wireEngineCallbacks()`, add after the `eng.onRouteChange` block:

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

**Step 3: Build and test**

```bash
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop/example/android
./gradlew :flutter_gapless_loop:assembleDebug :flutter_gapless_loop:testDebugUnitTest 2>&1 | tail -20
```

Expected: BUILD SUCCESSFUL, all 19 tests pass.

**Step 4: Commit**

```bash
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop
git add android/src/main/kotlin/com/fluttergaplessloop/LoopAudioEngine.kt \
        android/src/main/kotlin/com/fluttergaplessloop/FlutterGaplessLoopPlugin.kt
git commit -m "feat(android): wire BPM detection into LoopAudioEngine and FlutterGaplessLoopPlugin"
```

---

### Task 4: iOS — BpmDetector.swift (TDD)

**Files:**
- Replace: `example/ios/RunnerTests/RunnerTests.swift`
- Create: `ios/Classes/BpmDetector.swift`

**Context:** The existing `RunnerTests.swift` has a stale test calling `getPlatformVersion` which no longer exists. Replace the entire file with BpmDetector tests (keeping the import structure).

**Step 1: Replace RunnerTests.swift with BpmDetector tests**

Replace the entire content of `example/ios/RunnerTests/RunnerTests.swift`:

```swift
import XCTest
import AVFoundation
@testable import flutter_gapless_loop

// MARK: - Helpers

/// Creates a mono float PCM buffer with 10ms-wide amplitude pulses at every beat.
func makePulseBuffer(bpm: Double, sampleRate: Double = 44100, durationSecs: Double = 10.0) -> AVAudioPCMBuffer {
    let frameCount = AVAudioFrameCount(sampleRate * durationSecs)
    let format     = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    let buffer     = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
    buffer.frameLength = frameCount
    let data       = buffer.floatChannelData![0]
    let periodSamples = Int(sampleRate * 60.0 / bpm)
    let pulseLen   = Int(sampleRate * 0.01)  // 10ms
    var pos        = 0
    while pos < Int(frameCount) {
        let end = min(pos + pulseLen, Int(frameCount))
        for i in pos ..< end { data[i] = 1.0 }
        pos += periodSamples
    }
    return buffer
}

// MARK: - BpmDetectorTests

class BpmDetectorTests: XCTestCase {

    func testShortAudioReturnsZero() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!
        buffer.frameLength = 44100   // 1 second — below 2s minimum
        let result = BpmDetector.detect(buffer: buffer)
        XCTAssertEqual(result.bpm, 0.0, accuracy: 0.001, "Short audio should return bpm=0")
        XCTAssertTrue(result.beats.isEmpty, "Short audio should return empty beats")
    }

    func testSilenceReturnsZero() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100 * 5)!
        buffer.frameLength = 44100 * 5   // 5 seconds, all zeros
        let result = BpmDetector.detect(buffer: buffer)
        XCTAssertEqual(result.bpm, 0.0, accuracy: 0.001, "Silence should return bpm=0")
    }

    func test120BpmWithinTolerance() {
        let buffer = makePulseBuffer(bpm: 120)
        let result = BpmDetector.detect(buffer: buffer)
        XCTAssertLessThanOrEqual(abs(result.bpm - 120.0), 2.0,
            "Expected ~120 BPM, got \(result.bpm)")
        XCTAssertGreaterThan(result.confidence, 0.5,
            "Expected confidence > 0.5, got \(result.confidence)")
    }

    func test128BpmWithinTolerance() {
        let buffer = makePulseBuffer(bpm: 128)
        let result = BpmDetector.detect(buffer: buffer)
        XCTAssertLessThanOrEqual(abs(result.bpm - 128.0), 2.0,
            "Expected ~128 BPM, got \(result.bpm)")
    }

    func testBeatTimestampsMonotonicallyIncreasing() {
        let buffer = makePulseBuffer(bpm: 120)
        let result = BpmDetector.detect(buffer: buffer)
        XCTAssertGreaterThan(result.beats.count, 1, "Expected multiple beats")
        for i in 1 ..< result.beats.count {
            XCTAssertGreaterThan(result.beats[i], result.beats[i - 1],
                "Non-monotonic at index \(i): \(result.beats[i]) <= \(result.beats[i-1])")
        }
    }

    func testNoBeatsInMicroFadeRegion() {
        let buffer = makePulseBuffer(bpm: 120)
        let result = BpmDetector.detect(buffer: buffer)
        XCTAssertTrue(result.beats.allSatisfy { $0 >= 0.005 },
            "Found beat in micro-fade region: \(result.beats.filter { $0 < 0.005 })")
    }

    func testConfidenceInRange() {
        let buffer = makePulseBuffer(bpm: 120)
        let result = BpmDetector.detect(buffer: buffer)
        XCTAssertGreaterThanOrEqual(result.confidence, 0.0)
        XCTAssertLessThanOrEqual(result.confidence, 1.0)
    }
}
```

**Step 2: Verify the test file references BpmDetector (which doesn't exist yet)**

The file compiles only after `BpmDetector.swift` is created. For now just ensure the file is saved correctly.

**Step 3: Create BpmDetector.swift**

Create `ios/Classes/BpmDetector.swift`:

```swift
#if os(iOS)
import AVFoundation
import Foundation

// MARK: - BpmResult

/// The result of BPM/tempo detection.
public struct BpmResult {
    /// Estimated tempo in beats per minute. `0.0` if detection failed or was skipped.
    public let bpm: Double
    /// Confidence in [0.0, 1.0]. Values above 0.5 indicate reliable detection.
    public let confidence: Double
    /// Beat timestamps in seconds from the start of the file.
    public let beats: [Double]
}

// MARK: - BpmDetector

/// BPM/Tempo detector using the Ellis (2007) energy onset beat tracking algorithm.
///
/// All methods are pure functions — no shared mutable state, fully thread-safe.
///
/// Algorithm:
///  1. Mix stereo to mono; compute RMS energy per 512-sample frame (256-sample hop).
///  2. Positive half-wave rectified energy derivative → onset strength envelope.
///  3. Weighted autocorrelation (Gaussian prior at 120 BPM) → BPM estimate.
///  4. Dynamic programming forward pass → globally consistent beat sequence.
public enum BpmDetector {

    private static let frameSize: Int       = 512
    private static let hopSize: Int         = 256
    private static let minBpm               = 60.0
    private static let maxBpm               = 180.0
    private static let tempoPriorMean       = 120.0
    private static let tempoPriorSigma      = 30.0
    private static let dpLambda             = 100.0
    private static let minDurationSeconds   = 2.0

    /// Detects BPM and beat timestamps from a decoded `AVAudioPCMBuffer`.
    ///
    /// - Parameter buffer: Float PCM buffer with `floatChannelData`.
    /// - Returns: `BpmResult`. bpm=0 if audio is too short or silent.
    public static func detect(buffer: AVAudioPCMBuffer) -> BpmResult {
        let sampleRate   = buffer.format.sampleRate
        let channelCount = Int(buffer.format.channelCount)
        let totalFrames  = Int(buffer.frameLength)
        let duration     = Double(totalFrames) / sampleRate

        guard duration >= minDurationSeconds,
              let channelData = buffer.floatChannelData else {
            return BpmResult(bpm: 0, confidence: 0, beats: [])
        }

        // Stage 1: Onset strength envelope
        let mono  = mixToMono(channelData: channelData, channelCount: channelCount,
                              frameCount: totalFrames)
        var onset = computeOnsetStrength(mono: mono, frameCount: totalFrames)

        guard let maxOnset = onset.max(), maxOnset > 0 else {
            return BpmResult(bpm: 0, confidence: 0, beats: [])
        }
        for i in onset.indices { onset[i] /= maxOnset }

        // Stage 2: BPM estimation via weighted autocorrelation
        let lagMin = max(1, Int((sampleRate / (maxBpm / 60.0)) / Double(hopSize)))
        let lagMax = min(onset.count / 2, Int((sampleRate / (minBpm / 60.0)) / Double(hopSize)))

        guard lagMin < lagMax else {
            return BpmResult(bpm: 0, confidence: 0, beats: [])
        }

        let (ac, bestLagIdx) = autocorrelate(onset: onset, lagMin: lagMin,
                                             lagMax: lagMax, sampleRate: sampleRate)
        let actualLag    = bestLagIdx + lagMin
        let estimatedBpm = 60.0 * sampleRate / (Double(actualLag) * Double(hopSize))
        let confidence   = min(1.0, Double(ac[bestLagIdx]))

        // Stage 3: DP beat sequence
        let period = Int((sampleRate / (estimatedBpm / 60.0) / Double(hopSize)).rounded())
        let beats  = trackBeats(onset: onset, period: period, sampleRate: sampleRate)

        return BpmResult(bpm: estimatedBpm, confidence: confidence, beats: beats)
    }

    // MARK: - Private Helpers

    private static func mixToMono(
        channelData: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        frameCount: Int
    ) -> [Float] {
        if channelCount == 1 {
            return Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
        }
        return (0 ..< frameCount).map { f in
            var sum: Float = 0
            for ch in 0 ..< channelCount { sum += channelData[ch][f] }
            return sum / Float(channelCount)
        }
    }

    private static func computeOnsetStrength(mono: [Float], frameCount: Int) -> [Float] {
        let nFrames = (frameCount - frameSize) / hopSize + 1
        var rms = [Float](repeating: 0, count: nFrames)
        for f in 0 ..< nFrames {
            let start = f * hopSize
            var sumSq: Float = 0
            for i in start ..< start + frameSize { let s = mono[i]; sumSq += s * s }
            rms[f] = sqrtf(sumSq / Float(frameSize))
        }
        var onset = [Float](repeating: 0, count: nFrames)
        for f in 1 ..< nFrames { onset[f] = max(0, rms[f] - rms[f - 1]) }
        return onset
    }

    private static func autocorrelate(
        onset: [Float], lagMin: Int, lagMax: Int, sampleRate: Double
    ) -> ([Float], Int) {
        let n     = onset.count
        let nLags = lagMax - lagMin + 1
        var ac    = [Float](repeating: 0, count: nLags)

        for i in 0 ..< nLags {
            let lag   = lagMin + i
            let count = n - lag
            guard count > 0 else { continue }
            var sum: Double = 0
            for t in 0 ..< count { sum += Double(onset[t]) * Double(onset[t + lag]) }
            let normalized = sum / Double(count)
            let bpm = 60.0 * sampleRate / (Double(lag) * Double(hopSize))
            let z   = (bpm - tempoPriorMean) / tempoPriorSigma
            ac[i]   = Float(normalized * exp(-0.5 * z * z))
        }

        let maxAc = ac.max() ?? 0
        if maxAc > 0 { for i in ac.indices { ac[i] /= maxAc } }
        let bestIdx = ac.indices.max(by: { ac[$0] < ac[$1] }) ?? 0
        return (ac, bestIdx)
    }

    private static func trackBeats(onset: [Float], period: Int, sampleRate: Double) -> [Double] {
        let n = onset.count
        guard period > 0, n >= period else { return [] }

        var score = [Float](repeating: -.greatestFiniteMagnitude, count: n)
        var prev  = [Int](repeating: -1, count: n)
        for t in 0 ..< min(period * 2, n) { score[t] = onset[t] }

        let halfPeriod = period / 2
        let twoPeriod  = period * 2
        for t in period ..< n {
            for d in halfPeriod ... twoPeriod {
                let b = t - d
                guard b >= 0, score[b] > -.greatestFiniteMagnitude else { continue }
                let logR    = log(Double(d) / Double(period))
                let penalty = Float(dpLambda * logR * logR)
                let cand    = score[b] + onset[t] - penalty
                if cand > score[t] { score[t] = cand; prev[t] = b }
            }
        }

        var best = n - 1
        for t in max(0, n - period) ..< n where score[t] > score[best] { best = t }

        var beatFrames = [Int]()
        var t = best
        while t >= 0 && score[t] > -.greatestFiniteMagnitude {
            beatFrames.insert(t, at: 0)
            t = prev[t]
        }

        let microFadeSeconds = 0.005
        return beatFrames
            .map { Double($0) * Double(hopSize) / sampleRate }
            .filter { $0 >= microFadeSeconds }
    }
}
#endif // os(iOS)
```

**Step 4: Verify iOS compiles**

```bash
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop/example
flutter build ios --no-codesign 2>&1 | tail -15
```

Expected: `Built build/ios/iphoneos/Runner.app`

If there are Swift compile errors in BpmDetector.swift, fix them before proceeding.

**Step 5: Commit**

```bash
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop
git add ios/Classes/BpmDetector.swift example/ios/RunnerTests/RunnerTests.swift
git commit -m "feat(ios): add BpmDetector (Ellis 2007 energy onset beat tracker)"
```

---

### Task 5: iOS — Wire BPM into LoopAudioEngine and FlutterGaplessLoopPlugin

**Files:**
- Modify: `ios/Classes/LoopAudioEngine.swift`
- Modify: `ios/Classes/FlutterGaplessLoopPlugin.swift`

Read both files fully before editing.

**Step 1: Add callback + workItem + trigger to LoopAudioEngine.swift**

**Edit 1** — Add `onBpmDetected` callback near the other callbacks (after `onRouteChange`):

```swift
    /// Called when BPM detection completes after a load.
    /// Always dispatched to `DispatchQueue.main`.
    public var onBpmDetected: ((BpmResult) -> Void)?
```

**Edit 2** — Add `bpmWorkItem` property near the other private properties (after `originalBuffer`):

```swift
    /// Token for the in-flight background BPM detection task.
    /// Cancelled when a new file is loaded or dispose() is called.
    private var bpmWorkItem: DispatchWorkItem?
```

**Edit 3** — In `loadFile(url:)`, add `bpmWorkItem?.cancel()` as the FIRST line of the function body:

Before:
```swift
    public func loadFile(url: URL) throws {
        logger.info("loadFile: \(url.lastPathComponent)")

        // Phase 1: I/O off queue — safe since we only READ the file
        setState(.loading)
```

After:
```swift
    public func loadFile(url: URL) throws {
        logger.info("loadFile: \(url.lastPathComponent)")
        bpmWorkItem?.cancel()

        // Phase 1: I/O off queue — safe since we only READ the file
        setState(.loading)
```

**Edit 4** — In `loadFile(url:)`, after the `audioQueue.sync` block ends and after the engineStartError check, call `triggerBpmDetection`:

Find these lines near the end of `loadFile`:
```swift
        if let err = engineStartError {
            throw LoopEngineError.engineStartFailed(underlying: err)
        }
        logger.info("loadFile complete: duration=\(computedDuration)s")
```

Replace with:
```swift
        if let err = engineStartError {
            throw LoopEngineError.engineStartFailed(underlying: err)
        }
        triggerBpmDetection(buffer: buffer)
        logger.info("loadFile complete: duration=\(computedDuration)s")
```

(`buffer` is the local `AVAudioPCMBuffer` variable declared earlier in `loadFile`.)

**Edit 5** — In `dispose()`, add `bpmWorkItem?.cancel()` and `bpmWorkItem = nil` at the START of the function, before the `audioQueue.sync` block. Find the dispose method and insert before its `audioQueue.sync {`:

```swift
        bpmWorkItem?.cancel()
        bpmWorkItem = nil
```

**Edit 6** — Add the private `triggerBpmDetection` method in the `// MARK: - Private` section near the bottom of the class:

```swift
    // MARK: - Private: BPM Detection

    /// Launches BPM detection for `buffer` on a utility-priority background thread.
    /// On completion, dispatches `onBpmDetected` to the main queue.
    private func triggerBpmDetection(buffer: AVAudioPCMBuffer) {
        let workItem = DispatchWorkItem { [weak self] in
            let result = BpmDetector.detect(buffer: buffer)
            DispatchQueue.main.async { [weak self] in
                self?.onBpmDetected?(result)
            }
        }
        bpmWorkItem = workItem
        DispatchQueue.global(qos: .utility).async(execute: workItem)
    }
```

**Step 2: Wire onBpmDetected in FlutterGaplessLoopPlugin.swift**

In `setupEngine()`, add after the `eng.onRouteChange` closure block (before `engine = eng`):

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

**Step 3: Build to verify**

```bash
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop/example
flutter build ios --no-codesign 2>&1 | tail -15
```

Expected: `Built build/ios/iphoneos/Runner.app`

Fix any Swift compile errors before proceeding. Common issues:
- `bpmWorkItem` declared outside the `audioQueue` — this is intentional (DispatchWorkItem is thread-safe)
- `BpmResult` type conflict if there is a naming collision — the iOS type is `flutter_gapless_loop.BpmResult` from `BpmDetector.swift`

**Step 4: Commit**

```bash
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop
git add ios/Classes/LoopAudioEngine.swift ios/Classes/FlutterGaplessLoopPlugin.swift
git commit -m "feat(ios): wire BPM detection into LoopAudioEngine and FlutterGaplessLoopPlugin"
```

---

### Task 6: Final Verification

**Files:** Read-only verification pass — no code changes expected.

**Step 1: flutter pub get**

```bash
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop
flutter pub get
```

Expected: `Got dependencies!`

**Step 2: flutter analyze**

```bash
flutter analyze
```

Expected: `No issues found!`

If there are warnings about `BpmResult` being defined twice or similar, check that the Dart `BpmResult` is in `lib/src/loop_audio_state.dart` and not accidentally duplicated.

**Step 3: Android unit tests**

```bash
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop/example/android
./gradlew :flutter_gapless_loop:testDebugUnitTest 2>&1 | tail -25
```

Expected: All 19 tests PASS (11 original + 8 BpmDetectorTest).

**Step 4: Android APK build**

```bash
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop/example
flutter build apk --debug 2>&1 | tail -10
```

Expected: `Built build/app/outputs/flutter-apk/app-debug.apk`

**Step 5: iOS build**

```bash
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop/example
flutter build ios --no-codesign 2>&1 | tail -10
```

Expected: `Built build/ios/iphoneos/Runner.app`

**Step 6: Final commit if anything was fixed**

If any issues were fixed during verification, commit them. Otherwise just confirm all checks pass.

---

## Summary of All Changes

| File | Change |
|------|--------|
| `lib/src/loop_audio_state.dart` | Add `BpmResult` class |
| `lib/src/loop_audio_player.dart` | Add `bpmStream` getter |
| `test/flutter_gapless_loop_test.dart` | Add `BpmResult.fromMap` tests |
| `ios/Classes/BpmDetector.swift` | New file — full Ellis 2007 algorithm |
| `ios/Classes/LoopAudioEngine.swift` | Add `onBpmDetected`, `bpmWorkItem`, `triggerBpmDetection()` |
| `ios/Classes/FlutterGaplessLoopPlugin.swift` | Wire `onBpmDetected` to eventSink |
| `example/ios/RunnerTests/RunnerTests.swift` | Replace stale test; add `BpmDetectorTests` |
| `android/src/main/kotlin/.../BpmDetector.kt` | New file — full Ellis 2007 algorithm |
| `android/src/main/kotlin/.../LoopAudioEngine.kt` | Add `onBpmDetected`, `bpmJob`, `launchBpmDetection()` |
| `android/src/main/kotlin/.../FlutterGaplessLoopPlugin.kt` | Wire `onBpmDetected` to sendEvent |
| `android/src/test/.../FlutterGaplessLoopPluginTest.kt` | Add `BpmDetectorTest` (8 tests) |
