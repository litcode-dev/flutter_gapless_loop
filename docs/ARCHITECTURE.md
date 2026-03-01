# flutter_gapless_loop — Architecture

## Why AVPlayer Cannot Achieve Sample-Accurate Looping

`AVPlayer` uses a high-level media pipeline built on top of `AVFoundation`'s streaming infrastructure. The pipeline maintains a decode-ahead buffer queue; the decoder runs ahead of playback to smooth over I/O latency. When a loop boundary is reached, `AVPlayer` must:

1. Detect the end-of-item event (delivered on a background queue)
2. Issue a `seek(to: .zero)` command (which traverses the decode-ahead pipeline)
3. Wait for the decoder to re-prime its output buffer queue
4. Resume playback

This multi-step cycle introduces 20–200ms of audible silence at the loop boundary. Even with `AVPlayerLooper`, the API is built on top of `AVQueuePlayer` which still requires inter-item scheduling — audibly gapped on short loops.

`AVAudioPlayer` is slightly better but operates on a higher-level buffer ring and does not expose the render graph. Its loop is a software playback loop, not a hardware render loop.

## Why `scheduleBuffer(_:at:options: .loops)` Is Truly Gapless

`AVAudioPlayerNode.scheduleBuffer(_:at:options:completionCallbackType:completionHandler:)` with `options: .loops` registers the PCM buffer directly with the `AVAudioEngine` render tree.

The render tree's hardware callback (the `AudioUnit` render proc) runs at fixed intervals — at the default 256-frame buffer size and 44100 Hz sample rate, that is one callback every **5.8ms**. During each callback the render proc walks the node graph and mixes outputs into the hardware output buffer.

When `options: .loops` is set, the render proc wraps the read cursor back to frame 0 **within the same render cycle** — the instant the last frame of the buffer is consumed, the next frame read is frame 0. This happens at the sample level inside the render proc, without any Objective-C message passing, thread handoff, or scheduler involvement. The gap between the last frame of one iteration and the first frame of the next iteration is **zero samples**.

## Why the Micro-Fade Is Inaudible

A loop boundary click occurs when there is a sample value discontinuity: if the last sample of the buffer is `+0.8` and the first sample is `-0.3`, the render proc produces an instantaneous jump of `1.1` full-scale units. At 44100 Hz this is audible as a click.

The micro-fade mitigation applies a 5ms (220-sample) linear ramp at both ends of the buffer **at load time**:
- Fade-in: `sample[i] *= i / 220` for `i ∈ [0, 219]`
- Fade-out: `sample[N-1-i] *= i / 220` for `i ∈ [0, 219]`

Result: both endpoints approach 0.0 amplitude. When the loop wraps, the discontinuity energy is 0.0 — no click.

Why is 220 samples inaudible? Human auditory temporal resolution for click detection is approximately 1ms (44 samples). However, this threshold applies to broadband impulses with full-spectrum energy. A linear ramp from 0 to full amplitude over 220 samples has very low spectral energy at high frequencies — the ramp is essentially a very low-frequency modulation envelope. Musical content (which occupies 20Hz–20kHz) masks this envelope entirely.

## Sub-Buffer Extraction

When `setLoopRegion(start:end:)` is called, the engine extracts a sub-buffer from `originalBuffer` using direct pointer arithmetic:

```swift
let src = srcData[ch].advanced(by: Int(startFrame))
dst.initialize(from: src, count: Int(frameCount))
```

`floatChannelData` returns a `UnsafeMutablePointer<UnsafeMutablePointer<Float>>`. Advancing the inner pointer by `startFrame` elements gives a view into the original buffer's memory starting at the loop start frame. `initialize(from:count:)` performs a single `memcpy` of `frameCount × channelCount × 4` bytes — O(n) in frame count, O(1) extra allocation.

Zero-crossing alignment then scans a ±10ms window at each boundary for the nearest positive-going zero crossing and zeros out samples outside the valid range, minimising residual discontinuity energy.

## Equal-Power Crossfade Math

Equal-power crossfade uses complementary trigonometric gain ramps:
- Fade-out gain: `G_out(t) = cos(t × π/2)`
- Fade-in gain: `G_in(t) = sin(t × π/2)`
- Where `t ∈ [0, 1]` progresses linearly across the crossfade duration

The critical property: `G_out²(t) + G_in²(t) = cos²(θ) + sin²(θ) = 1` for all θ.

This means the summed **power** of the two signals is constant throughout the crossfade, eliminating the perceived loudness dip that a linear crossfade produces at its midpoint.

## Mode Selection State Machine

```
Initial state: Mode A

setLoopRegion() called       →  Mode B (or D if crossfade > 0)
setCrossfadeDuration(> 0)    →  Mode C (or D if loop region set)
setCrossfadeDuration(0)      →  Mode A (or B if loop region set)

Mode A: nodeA scheduleBuffer(.loops) on originalBuffer
Mode B: nodeA scheduleBuffer(.loops) on loopBuffer (sub-buffer)
Mode C: nodeA on originalBuffer + nodeB crossfade timed to loop boundary
Mode D: nodeA on loopBuffer    + nodeB crossfade timed to loop boundary
```

The mode is re-evaluated at every `scheduleForCurrentMode()` call (called from `play()` and from reschedule paths in `setLoopRegion`). No locks required — the serial `audioQueue` serializes all mode transitions.

## Thread Safety

All mutable engine state is exclusively accessed on the dedicated serial `audioQueue` (QoS `.userInteractive`). This queue acts as the synchronisation mechanism:
- Reads of `_state`, `currentTime`, `duration` from external threads use `audioQueue.sync`
- All writes are async dispatched to `audioQueue`
- `loadFile` uses `audioQueue.sync` for the state-commit phase after file I/O
- No `os_unfair_lock`, `NSLock`, or `DispatchSemaphore` required — the serial queue provides equivalent exclusivity with lower overhead

Flutter result callbacks are always dispatched to `DispatchQueue.main` — the Flutter platform channel contract requires result callbacks on the main thread.
