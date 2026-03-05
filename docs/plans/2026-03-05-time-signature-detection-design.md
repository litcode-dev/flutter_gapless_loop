# Time Signature Detection — Design

**Date:** 2026-03-05
**Status:** Approved

## Overview

Add meter (time signature) detection to the existing BPM detection pipeline. After each load the plugin will emit `beatsPerBar` (e.g. 3 or 4) and `bars` (bar start timestamps in seconds) alongside the existing `bpm`, `confidence`, and `beats` fields.

## Algorithm — Approach A: Bar-level autocorrelation

Meter detection runs as **Stage 4** of `BpmDetector.detect()`, immediately after the DP beat-tracking pass. No additional audio I/O or buffer passes are needed.

1. For each candidate meter `m` in `{2, 3, 4, 6, 7}`, compute the autocorrelation of the already-normalised onset envelope at lag `m × beatPeriod` frames.
2. Apply a Gaussian prior favouring `m = 4` (σ = 1.5 meters) to reflect the prevalence of 4/4 in loop sample content.
3. Select the `m` with the highest weighted score → `beatsPerBar`.
4. Compute `bars`: find the beat index with the highest onset strength (strongest downbeat candidate), then step forward and backward through the beat list at every `beatsPerBar`-th index to collect bar start timestamps.
5. **Confidence guard:** if `BpmResult.confidence < 0.3`, return `beatsPerBar = 0` and `bars = []` to signal detection was unreliable.

## API

### Dart — `BpmResult` (additive, no breaking change)

```dart
class BpmResult {
  final double bpm;
  final double confidence;
  final List<double> beats;
  final int beatsPerBar;      // 0 = unknown
  final List<double> bars;    // bar start timestamps in seconds
}
```

### Event channel payload (`bpmDetected`)

```dart
{
  'type': 'bpmDetected',
  'bpm': 120.0,
  'confidence': 0.85,
  'beats': [0.5, 1.0, ...],
  'beatsPerBar': 4,
  'bars': [0.5, 2.5, 4.5, ...]
}
```

### Native structs

- **iOS** `BpmResult`: add `beatsPerBar: Int` and `bars: [Double]`.
- **Android** `BpmDetectionResult`: add `beatsPerBar: Int` and `bars: List<Double>`.

## Integration Points

| File | Change |
|------|--------|
| `ios/Classes/BpmDetector.swift` | Add private `detectMeter(onset:beatPeriod:beats:sampleRate:)` helper; call at end of `detect()`; extend `BpmResult` struct |
| `ios/Classes/FlutterGaplessLoopPlugin.swift` | Add `beatsPerBar` + `bars` keys to `bpmDetected` event map |
| `android/.../BpmDetector.kt` | Add private `detectMeter(...)` helper; extend `BpmDetectionResult` data class |
| `android/.../FlutterGaplessLoopPlugin.kt` | Add `beatsPerBar` + `bars` keys to `bpmDetected` event map |
| `lib/src/loop_audio_state.dart` | Add fields to `BpmResult`; update `fromMap` factory |

No changes to engine, channels, or playback logic. Example app display of `beatsPerBar` is optional.

## Testing

**Android** (existing `FlutterGaplessLoopPluginTest.kt`):
- 4/4 click track (sine bursts every beat period) → `beatsPerBar == 4`
- 3/4 waltz click track → `beatsPerBar == 3`
- Silent / too-short audio → `beatsPerBar == 0`, `bars` empty

**iOS:** Add equivalent cases to the plugin unit test target.

## Non-goals

- Denominator detection (4/4 vs 4/8) — not acoustically distinguishable; out of scope.
- Live/streaming meter detection — only runs once per load, same as BPM.
- ML-based approaches — out of scope.
