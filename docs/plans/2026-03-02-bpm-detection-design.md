# BPM/Tempo Detection — Design Document
**Date:** 2026-03-02
**Author:** Claude
**Status:** Approved

---

## Goal

Add automatic BPM/Tempo detection to `flutter_gapless_loop` for both iOS and Android. Detection runs in the background immediately after every `load()` / `loadFromFile()` call, operating on the already-decoded PCM buffer already in memory. Results are delivered to Dart via a new `bpmStream` on `LoopAudioPlayer`.

---

## Algorithm: Ellis (2007) Energy Onset Beat Tracker

Chosen over simple autocorrelation (octave errors) and spectral flux + tempogram (requires FFT, more complex). The Ellis algorithm is proven, accurate to ±1–2 BPM on loop-oriented audio, and implementable in pure Swift/Kotlin with no external dependencies.

### Stage 1 — Onset Strength Envelope

1. Mix stereo to mono (average channels); mono files pass through unchanged.
2. Slice into overlapping frames: **frameSize = 512 samples, hopSize = 256 samples** (~11.6ms / ~5.8ms hop at 44.1kHz; proportional at other sample rates).
3. Compute RMS energy per frame: `rms[f] = sqrt(mean(samples[f*hop .. f*hop+frameSize]²))`
4. Positive half-wave rectified derivative: `onset[f] = max(0, rms[f] − rms[f−1])`
5. Normalize onset to [0, 1] by dividing by max value. If max = 0 (silence), return zero result.

### Stage 2 — BPM Estimation via Autocorrelation

1. Compute the autocorrelation of the onset envelope over the lag range corresponding to 60–180 BPM:
   - `lagMin = floor(sampleRate / (180/60) / hopSize)` (frames per beat at 180 BPM)
   - `lagMax = ceil(sampleRate / (60/60) / hopSize)` (frames per beat at 60 BPM)
   - `ac[L] = Σ onset[t] * onset[t+L]` for all valid t, normalized by (nFrames − L)
2. Apply Gaussian tempo prior centered at 120 BPM (σ = 30 BPM) to break octave ties:
   - `bpm(L) = 60 * sampleRate / (L * hopSize)`
   - `weight[L] = exp(−0.5 * ((bpm(L) − 120) / 30)²)`
   - `weightedAc[L] = ac[L] * weight[L]`
3. `bestLag = argmax(weightedAc[lagMin..lagMax])`
4. `estimatedBpm = 60 * sampleRate / (bestLag * hopSize)`
5. **Confidence** = Pearson-normalized autocorrelation peak, clamped to [0, 1]:
   `confidence = ac[bestLag] / ac[0]` (ratio of lag-P correlation to zero-lag energy)

### Stage 3 — Beat Sequence via Dynamic Programming

1. Period in frames: `P = round(sampleRate / (estimatedBpm / 60) / hopSize)`
2. Forward pass (O(n)):
   ```
   score[t] = onset[t] + max over d in [P/2 .. 2P]:
                 score[t − d] − λ * (log(d/P))²
   ```
   where **λ = 100** (penalty weight for deviation from estimated period).
3. Backtrack from `argmax(score[nFrames−P .. nFrames−1])` to extract beat frame indices.
4. Convert to timestamps: `beat_seconds[i] = frameIndex * hopSize / sampleRate`
5. Strip any beats in first 5ms (micro-fade region).

### Short-File Guard

If `totalFrames < sampleRate * 2` (less than 2 seconds), skip analysis and return `BpmResult(bpm: 0.0, confidence: 0.0, beats: [])`.

### Expected Runtime

~50–80ms on a 3-minute 44.1kHz stereo file on modern mobile hardware. Runs entirely on a background thread; playback is never blocked.

---

## Dart API Changes

### New type — `lib/src/loop_audio_state.dart`

```dart
class BpmResult {
  final double bpm;         // e.g. 128.0; 0.0 if detection failed/skipped
  final double confidence;  // [0.0, 1.0]; 0.0 = no result
  final List<double> beats; // beat timestamps in seconds from file start

  const BpmResult({
    required this.bpm,
    required this.confidence,
    required this.beats,
  });

  factory BpmResult.fromMap(Map<Object?, Object?> map) => BpmResult(
    bpm: (map['bpm'] as num).toDouble(),
    confidence: (map['confidence'] as num).toDouble(),
    beats: (map['beats'] as List).map((e) => (e as num).toDouble()).toList(),
  );
}
```

### New stream — `lib/src/loop_audio_player.dart`

```dart
Stream<BpmResult> get bpmStream;
```

Wired to the existing event channel; fires when the native side sends a `{"type": "bpmDetected", ...}` event.

### No new method channel methods

BPM results are delivered only via the event stream. No `detectBpm()` call is added.

---

## Native Event Payload

```json
{
  "type": "bpmDetected",
  "bpm": 128.0,
  "confidence": 0.94,
  "beats": [0.23, 0.70, 1.17, 1.64, 2.11]
}
```

Beats array is a flat list of `Double` values; for long files (5+ min) this could be 300–500 elements. Transfer via method channel is negligible in size.

---

## File Structure

### New files

| File | Purpose |
|------|---------|
| `ios/Classes/BpmDetector.swift` | Pure Swift struct. Single static `detect(buffer: AVAudioPCMBuffer) -> BpmResult` function. No AVFoundation dependency beyond the buffer type. |
| `android/src/main/kotlin/com/fluttergaplessloop/BpmDetector.kt` | Pure Kotlin object. Single `detect(pcm: FloatArray, sampleRate: Int, channelCount: Int): BpmResult` function. |

### Modified files (minimal)

| File | Change |
|------|--------|
| `ios/Classes/LoopAudioEngine.swift` | After transitioning to `.ready`, dispatch `BpmDetector.detect(originalBuffer)` on a `.utility` background queue. On completion, fire `bpmDetected` event via callback. Store `DispatchWorkItem` to cancel on `dispose()`. |
| `android/src/main/kotlin/com/fluttergaplessloop/LoopAudioEngine.kt` | After transitioning to `Ready`, launch `BpmDetector.detect(...)` in `engineScope` on `Dispatchers.IO`. On completion, post `bpmDetected` event via `onBpmDetected` callback on `Dispatchers.Main`. Cancel automatically when scope is cancelled in `dispose()`. |
| `lib/src/loop_audio_state.dart` | Add `BpmResult` class. |
| `lib/src/loop_audio_player.dart` | Add `bpmStream` getter; wire `bpmDetected` event from raw event stream. |

`FlutterGaplessLoopPlugin.swift` and `FlutterGaplessLoopPlugin.kt` require **no changes** — the event channel already passes through arbitrary `Map<String, Any>` / `Map<String, Any?>` payloads.

---

## Threading Model

| Platform | Analysis thread | Event dispatch |
|----------|----------------|----------------|
| iOS | `DispatchQueue.global(qos: .utility)` | `DispatchQueue.main.async` |
| Android | `Dispatchers.IO` coroutine in `engineScope` | `Dispatchers.Main` via callback |

**Cancel safety:**
- iOS: `DispatchWorkItem` stored as `bpmWorkItem`; cancelled in `dispose()` and at the start of each new `loadFile()`.
- Android: coroutine job stored as `bpmJob`; cancelled by `engineScope.cancel()` in `dispose()` and `bpmJob?.cancel()` at start of each `loadFile()`.

---

## Error Handling

| Condition | Behavior |
|-----------|----------|
| Audio < 2 seconds | Skip analysis; fire `bpmDetected` with `bpm=0, confidence=0, beats=[]` |
| Silence (onset envelope all-zeros) | Skip DP stage; fire `bpmDetected` with `bpm=0, confidence=0, beats=[]` |
| `dispose()` called during analysis | iOS: `DispatchWorkItem.cancel()`; Android: job cancellation. No event fired. |
| Mono file | No stereo mix-down; algorithm runs directly on mono samples |
| Non-standard sample rates | All frame/lag sizes computed from `sampleRate` parameter; fully agnostic |

---

## iOS Concept Mapping

| iOS API | Role |
|---------|------|
| `originalBuffer: AVAudioPCMBuffer` | Source PCM data (float, planar layout) |
| `originalBuffer.format.sampleRate` | Sample rate (Double → Int) |
| `originalBuffer.floatChannelData![ch][frame]` | Per-channel per-frame sample access |
| `DispatchWorkItem` | Cancellable background task token |

## Android Concept Mapping

| Android API | Role |
|-------------|------|
| `pcmBuffer: FloatArray` | Source PCM data (interleaved layout) |
| `sampleRate: Int` | Sample rate |
| `channelCount: Int` | 1 or 2 |
| `Job` (coroutine) | Cancellable background task token |
