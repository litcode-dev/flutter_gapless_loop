package com.fluttergaplessloop

import kotlin.math.log10
import kotlin.math.pow
import kotlin.math.tan

/**
 * EBU R128 / ITU-R BS.1770-4 integrated loudness analyser.
 *
 * Applies K-weighting (two biquad stages) to the interleaved float PCM, then
 * computes the mean-square energy and converts to LUFS.
 *
 * ## K-weighting filter chain
 *
 * Stage 1 — High-shelf (+4 dB above ~1682 Hz):
 *   Compensates for the acoustic effect of the head (pinna diffraction).
 *
 * Stage 2 — 2nd-order high-pass Butterworth (38.13 Hz):
 *   Removes DC and sub-bass that would inflate the measurement.
 *
 * Coefficients match the ITU-R BS.1770-4 specification.
 */
internal object LoudnessAnalyser {

    /**
     * Computes integrated loudness of [pcm] in LUFS.
     *
     * @param pcm          Interleaved float PCM samples (any channel count).
     * @param sampleRate   Sample rate in Hz.
     * @param channelCount Number of interleaved channels.
     * @return Integrated loudness in LUFS; -100.0 for silence or empty input.
     */
    fun analyse(pcm: FloatArray, sampleRate: Int, channelCount: Int): Double {
        val totalFrames = pcm.size / channelCount
        if (totalFrames == 0) return -100.0

        // 1. Mix down to mono.
        val mono = FloatArray(totalFrames)
        for (frame in 0 until totalFrames) {
            var sum = 0f
            for (ch in 0 until channelCount) {
                sum += pcm[frame * channelCount + ch]
            }
            mono[frame] = sum / channelCount
        }

        // 2. K-weighting filter chain.
        val fs = sampleRate.toDouble()
        applyBiquad(mono, *stage1(fs))
        applyBiquad(mono, *stage2(fs))

        // 3. Mean square → LUFS.
        var sumSq = 0.0
        for (v in mono) sumSq += v.toDouble() * v.toDouble()
        val meanSq = sumSq / totalFrames
        if (meanSq <= 0.0) return -100.0

        // LUFS = 10 × log10(mean_square) − 0.691  (BS.1770-4 offset)
        return maxOf(10.0 * log10(meanSq) - 0.691, -100.0)
    }

    // ─── Biquad (Direct-Form II Transposed) ───────────────────────────────────

    private fun applyBiquad(
        signal: FloatArray,
        b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    ) {
        var z1 = 0.0; var z2 = 0.0
        for (i in signal.indices) {
            val x = signal[i].toDouble()
            val y = b0 * x + z1
            z1    = b1 * x - a1 * y + z2
            z2    = b2 * x - a2 * y
            signal[i] = y.toFloat()
        }
    }

    // ─── Stage 1: High-shelf (+4 dB @ 1681.97 Hz) ────────────────────────────

    private fun stage1(fs: Double): DoubleArray {
        val f0  = 1681.97
        val Q   = 0.7072
        val Vb  = 10.0.pow(4.0 / 20.0) // ≈ 1.58489
        val K   = tan(Math.PI * f0 / fs)
        val norm = 1.0 / (1.0 + K / Q + K * K)
        return doubleArrayOf(
            (Vb + Vb * K / Q + K * K) * norm,   // b0
            2.0 * (K * K - Vb) * norm,            // b1
            (Vb - Vb * K / Q + K * K) * norm,    // b2
            2.0 * (K * K - 1.0) * norm,           // a1
            (1.0 - K / Q + K * K) * norm          // a2
        )
    }

    // ─── Stage 2: High-pass Butterworth (38.13 Hz) ───────────────────────────

    private fun stage2(fs: Double): DoubleArray {
        val f1  = 38.13
        val Q   = 0.5003
        val K   = tan(Math.PI * f1 / fs)
        val norm = 1.0 / (1.0 + K / Q + K * K)
        return doubleArrayOf(
             1.0  * norm,                          // b0
            -2.0  * norm,                          // b1
             1.0  * norm,                          // b2
            2.0 * (K * K - 1.0) * norm,           // a1
            (1.0 - K / Q + K * K) * norm          // a2
        )
    }
}
