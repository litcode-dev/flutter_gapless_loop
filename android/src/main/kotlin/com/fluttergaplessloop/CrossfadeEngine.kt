package com.fluttergaplessloop

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/**
 * Pre-computes an equal-power crossfade ramp and blends loop-boundary samples.
 *
 * Equal-power formula:
 *   fadeOut[i] = cos²(i / N * π/2)  → 1.0 at i=0, ~0.0 at i=N
 *   fadeIn[i]  = sin²(i / N * π/2)  → 0.0 at i=0,  1.0 at i=N
 *
 * The equal-power property (cos²θ + sin²θ = 1) ensures constant perceived
 * loudness across the transition: with unity-amplitude inputs the blended
 * amplitude remains 1.0 at every point, matching the iOS AVAudioMixerNode behavior.
 *
 * All computation happens in [configure]; [computeCrossfadeBlock] is O(N)
 * multiply-add and is safe to call from setup code (not from the inner write loop).
 *
 * @param sampleRate   Audio sample rate in Hz.
 * @param channelCount Number of interleaved channels (1 = mono, 2 = stereo).
 */
class CrossfadeEngine(
    private val sampleRate: Int,
    private val channelCount: Int
) {
    private var fadeOutRamp: FloatArray = FloatArray(0)
    private var fadeInRamp:  FloatArray = FloatArray(0)

    /**
     * Number of audio frames in the crossfade window. 0 means not yet configured.
     * Read by [LoopAudioEngine] to know how many samples to extract for the block.
     */
    var fadeFrames: Int = 0
        private set

    /**
     * Pre-computes the equal-power ramps for [durationSeconds].
     *
     * Must be called before [computeCrossfadeBlock]. Safe to call again when
     * the crossfade duration changes — ramps are fully replaced.
     *
     * @param durationSeconds Crossfade length in seconds. Must be > 0.
     */
    fun configure(durationSeconds: Double) {
        fadeFrames = (sampleRate * durationSeconds).toInt()
        val n = fadeFrames.toFloat()
        // Equal-power ramps using squared cosine/sine so that fadeOut + fadeIn = 1
        // at every point: cos²(θ) + sin²(θ) = 1. This preserves constant perceived
        // loudness while keeping the blended amplitude flat when both inputs are unity.
        fadeOutRamp = FloatArray(fadeFrames) { i ->
            val c = cos(i / n * (PI / 2.0)).toFloat(); c * c
        }
        fadeInRamp  = FloatArray(fadeFrames) { i ->
            val s = sin(i / n * (PI / 2.0)).toFloat(); s * s
        }
    }

    /**
     * Blends [tailSamples] (end of loop) and [headSamples] (start of loop) using
     * the pre-computed equal-power ramps.
     *
     * Both arrays must be interleaved PCM with length `fadeFrames * channelCount`.
     * Returns a new [FloatArray] of the same length ready to write to [AudioTrack].
     *
     * Pre-compute this result and cache it — do NOT call from inside the write loop.
     *
     * @throws IllegalArgumentException if tail and head sizes differ.
     */
    fun computeCrossfadeBlock(tailSamples: FloatArray, headSamples: FloatArray): FloatArray {
        require(tailSamples.size == headSamples.size) {
            "tail (${tailSamples.size}) and head (${headSamples.size}) must match"
        }
        val out = FloatArray(tailSamples.size)
        for (frame in 0 until fadeFrames) {
            val rampIdx = frame.coerceAtMost(fadeFrames - 1)
            val fo = fadeOutRamp[rampIdx]
            val fi = fadeInRamp[rampIdx]
            for (ch in 0 until channelCount) {
                val idx = frame * channelCount + ch
                out[idx] = tailSamples[idx] * fo + headSamples[idx] * fi
            }
        }
        return out
    }

    /**
     * Resets all state. Call when the user removes crossfade or changes loop region
     * so a stale block is never applied at the loop boundary.
     */
    fun reset() {
        fadeFrames  = 0
        fadeOutRamp = FloatArray(0)
        fadeInRamp  = FloatArray(0)
    }
}
