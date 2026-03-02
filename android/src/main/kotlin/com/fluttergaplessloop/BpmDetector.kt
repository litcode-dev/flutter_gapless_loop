package com.fluttergaplessloop

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
