package com.fluttergaplessloop

import kotlin.math.*

/**
 * Single biquad (second-order IIR) filter for real-time audio DSP.
 *
 * Implements the Direct Form II (DF-II) transposed structure:
 *   y[n] = b0*x[n] + b1*x[n-1] + b2*x[n-2] - a1*y[n-1] - a2*y[n-2]
 *
 * Coefficient formulas from the Audio EQ Cookbook (R. Bristow-Johnson).
 *
 * One [BiquadFilter] instance processes a single audio channel. For stereo,
 * create two instances with the same coefficients (they maintain independent state).
 *
 * Not thread-safe. Intended to be called exclusively from the write thread.
 */
internal class BiquadFilter {

    // ── Coefficients (normalised by a0) ────────────────────────────────────────
    private var b0 = 1.0f
    private var b1 = 0.0f
    private var b2 = 0.0f
    private var a1 = 0.0f   // stored as -a1 (sign already flipped)
    private var a2 = 0.0f   // stored as -a2 (sign already flipped)

    // ── DF-II state ────────────────────────────────────────────────────────────
    private var w1 = 0.0f
    private var w2 = 0.0f

    /** Resets filter memory (call after a seek or when filter is re-configured). */
    fun reset() {
        w1 = 0f; w2 = 0f
    }

    /**
     * Processes one sample [x] and returns the filtered output.
     *
     * Direct Form II Transposed:
     *   y = b0*x + w1
     *   w1 = b1*x - a1*y + w2
     *   w2 = b2*x - a2*y
     */
    fun process(x: Float): Float {
        val y = b0 * x + w1
        w1 = b1 * x - a1 * y + w2
        w2 = b2 * x - a2 * y
        return y
    }

    /** Bypasses the filter (all-pass: b0=1, b1=b2=a1=a2=0). */
    fun setBypass() {
        b0 = 1f; b1 = 0f; b2 = 0f; a1 = 0f; a2 = 0f
        reset()
    }

    /**
     * Low-shelf filter at [freqHz] with [gainDb] boost/cut (±12 dB).
     * Shelf slope S is fixed at 1 (unity slope).
     */
    fun setLowShelf(freqHz: Float, gainDb: Float, sampleRate: Int) {
        if (gainDb == 0f) { setBypass(); return }
        val A  = 10f.pow(gainDb / 40f)
        val w0 = 2f * PI.toFloat() * freqHz / sampleRate
        val cosW0 = cos(w0)
        val sinW0 = sin(w0)
        // For shelf slope S=1: alpha_s = sinW0/2 * sqrt(2)
        val alpha = sinW0 * sqrt(2f) / 2f

        val sqrtA = sqrt(A)
        val b0n =     A * ((A + 1f) - (A - 1f) * cosW0 + 2f * sqrtA * alpha)
        val b1n = 2f * A * ((A - 1f) - (A + 1f) * cosW0)
        val b2n =     A * ((A + 1f) - (A - 1f) * cosW0 - 2f * sqrtA * alpha)
        val a0n =          (A + 1f) + (A - 1f) * cosW0 + 2f * sqrtA * alpha
        val a1n =    -2f * ((A - 1f) + (A + 1f) * cosW0)
        val a2n =          (A + 1f) + (A - 1f) * cosW0 - 2f * sqrtA * alpha

        setCoefficients(b0n, b1n, b2n, a0n, a1n, a2n)
    }

    /**
     * High-shelf filter at [freqHz] with [gainDb] boost/cut (±12 dB).
     */
    fun setHighShelf(freqHz: Float, gainDb: Float, sampleRate: Int) {
        if (gainDb == 0f) { setBypass(); return }
        val A  = 10f.pow(gainDb / 40f)
        val w0 = 2f * PI.toFloat() * freqHz / sampleRate
        val cosW0 = cos(w0)
        val sinW0 = sin(w0)
        val alpha = sinW0 * sqrt(2f) / 2f

        val sqrtA = sqrt(A)
        val b0n =      A * ((A + 1f) + (A - 1f) * cosW0 + 2f * sqrtA * alpha)
        val b1n = -2f * A * ((A - 1f) + (A + 1f) * cosW0)
        val b2n =      A * ((A + 1f) + (A - 1f) * cosW0 - 2f * sqrtA * alpha)
        val a0n =           (A + 1f) - (A - 1f) * cosW0 + 2f * sqrtA * alpha
        val a1n =     2f * ((A - 1f) - (A + 1f) * cosW0)
        val a2n =           (A + 1f) - (A - 1f) * cosW0 - 2f * sqrtA * alpha

        setCoefficients(b0n, b1n, b2n, a0n, a1n, a2n)
    }

    /**
     * Peaking EQ filter at [freqHz] with [gainDb] boost/cut and [bwOctaves] bandwidth.
     */
    fun setPeaking(freqHz: Float, gainDb: Float, bwOctaves: Float, sampleRate: Int) {
        if (gainDb == 0f) { setBypass(); return }
        val A  = 10f.pow(gainDb / 40f)
        val w0 = 2f * PI.toFloat() * freqHz / sampleRate
        val sinW0 = sin(w0)
        val cosW0 = cos(w0)
        // alpha using bandwidth in octaves
        val alpha = sinW0 * sinh(ln(2.0) / 2.0 * bwOctaves * w0 / sinW0).toFloat()

        val b0n = 1f + alpha * A
        val b1n = -2f * cosW0
        val b2n = 1f - alpha * A
        val a0n = 1f + alpha / A
        val a1n = -2f * cosW0
        val a2n = 1f - alpha / A

        setCoefficients(b0n, b1n, b2n, a0n, a1n, a2n)
    }

    /**
     * Butterworth low-pass filter at [freqHz] with resonance [q] (Q factor).
     * Q=0.707 = Butterworth (no resonance peak).
     */
    fun setLowPass(freqHz: Float, q: Float, sampleRate: Int) {
        val w0 = 2f * PI.toFloat() * freqHz / sampleRate
        val cosW0 = cos(w0)
        val sinW0 = sin(w0)
        val alpha = sinW0 / (2f * q)

        val b0n = (1f - cosW0) / 2f
        val b1n =  1f - cosW0
        val b2n = (1f - cosW0) / 2f
        val a0n =  1f + alpha
        val a1n = -2f * cosW0
        val a2n =  1f - alpha

        setCoefficients(b0n, b1n, b2n, a0n, a1n, a2n)
    }

    /**
     * Butterworth high-pass filter at [freqHz] with resonance [q] (Q factor).
     */
    fun setHighPass(freqHz: Float, q: Float, sampleRate: Int) {
        val w0 = 2f * PI.toFloat() * freqHz / sampleRate
        val cosW0 = cos(w0)
        val sinW0 = sin(w0)
        val alpha = sinW0 / (2f * q)

        val b0n =  (1f + cosW0) / 2f
        val b1n = -(1f + cosW0)
        val b2n =  (1f + cosW0) / 2f
        val a0n =   1f + alpha
        val a1n =  -2f * cosW0
        val a2n =   1f - alpha

        setCoefficients(b0n, b1n, b2n, a0n, a1n, a2n)
    }

    // ── Private ────────────────────────────────────────────────────────────────

    private fun setCoefficients(b0n: Float, b1n: Float, b2n: Float,
                                a0n: Float, a1n: Float, a2n: Float) {
        b0 =  b0n / a0n
        b1 =  b1n / a0n
        b2 =  b2n / a0n
        a1 =  a1n / a0n  // note: sign is negative in y[n] equation → store as-is,
        a2 =  a2n / a0n  //       the process() function subtracts a1*y + a2*y
        reset()
    }
}

/**
 * A bank of [BiquadFilter] instances for a full EQ + cutoff filter chain.
 *
 * Supports up to [channelCount] channels and 4 serial filter stages:
 *   0 = low shelf (80 Hz)
 *   1 = peaking   (1 kHz)
 *   2 = high shelf (10 kHz)
 *   3 = cutoff (low-pass or high-pass, configurable)
 *
 * Designed to be owned by [LoopAudioEngine] and called exclusively from the write thread.
 */
internal class BiquadFilterBank(val channelCount: Int) {

    // 4 stages × channelCount filters
    private val filters = Array(4) { Array(channelCount) { BiquadFilter() } }

    /** Processes [numSamples] of interleaved PCM in-place. */
    fun process(buffer: FloatArray, numSamples: Int) {
        for (i in 0 until numSamples) {
            val ch = i % channelCount
            var sample = buffer[i]
            // Apply all 4 stages serially
            sample = filters[0][ch].process(sample)
            sample = filters[1][ch].process(sample)
            sample = filters[2][ch].process(sample)
            sample = filters[3][ch].process(sample)
            buffer[i] = sample
        }
    }

    /** Sets low-shelf EQ (band 0, 80 Hz). */
    fun setLowShelf(gainDb: Float, sampleRate: Int) {
        for (ch in 0 until channelCount)
            filters[0][ch].setLowShelf(80f, gainDb, sampleRate)
    }

    /** Sets peaking EQ (band 1, 1 kHz, 1-octave bandwidth). */
    fun setPeaking(gainDb: Float, sampleRate: Int) {
        for (ch in 0 until channelCount)
            filters[1][ch].setPeaking(1000f, gainDb, 1.0f, sampleRate)
    }

    /** Sets high-shelf EQ (band 2, 10 kHz). */
    fun setHighShelf(gainDb: Float, sampleRate: Int) {
        for (ch in 0 until channelCount)
            filters[2][ch].setHighShelf(10000f, gainDb, sampleRate)
    }

    /** Sets the cutoff filter (band 3). [type] 0 = low-pass, 1 = high-pass. */
    fun setCutoff(cutoffHz: Float, type: Int, resonance: Float, sampleRate: Int) {
        val q = resonance.coerceIn(0.1f, 10.0f)
        for (ch in 0 until channelCount) {
            if (type == 1)
                filters[3][ch].setHighPass(cutoffHz.coerceIn(20f, 20000f), q, sampleRate)
            else
                filters[3][ch].setLowPass(cutoffHz.coerceIn(20f, 20000f), q, sampleRate)
        }
    }

    /** Bypasses all EQ bands (0-2), leaving cutoff unchanged. */
    fun bypassEq() {
        for (stage in 0..2)
            for (ch in 0 until channelCount) filters[stage][ch].setBypass()
    }

    /** Bypasses the cutoff filter (band 3). */
    fun bypassCutoff() {
        for (ch in 0 until channelCount) filters[3][ch].setBypass()
    }

    /** Resets all filter state (call after seek). */
    fun resetState() {
        for (stage in 0..3)
            for (ch in 0 until channelCount) filters[stage][ch].reset()
    }
}
