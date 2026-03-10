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
    /// Estimated beats per bar (time signature numerator). `0` if unknown (low confidence or
    /// audio too short). Typical values: 2, 3, 4, 6, 7.
    public let beatsPerBar: Int
    /// Bar start timestamps in seconds. Empty if `beatsPerBar` is 0.
    public let bars: [Double]
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
            return BpmResult(bpm: 0, confidence: 0, beats: [], beatsPerBar: 0, bars: [])
        }

        // Stage 1: Onset strength envelope
        let mono  = mixToMono(channelData: channelData, channelCount: channelCount,
                              frameCount: totalFrames)
        var onset = computeOnsetStrength(mono: mono, frameCount: totalFrames)

        guard let maxOnset = onset.max(), maxOnset > 0 else {
            return BpmResult(bpm: 0, confidence: 0, beats: [], beatsPerBar: 0, bars: [])
        }
        for i in onset.indices { onset[i] /= maxOnset }

        // Stage 2: BPM estimation via weighted autocorrelation
        let lagMin = max(1, Int((sampleRate / (maxBpm / 60.0)) / Double(hopSize)))
        let lagMax = min(onset.count / 2, Int(ceil((sampleRate / (minBpm / 60.0)) / Double(hopSize))))

        guard lagMin < lagMax else {
            return BpmResult(bpm: 0, confidence: 0, beats: [], beatsPerBar: 0, bars: [])
        }

        let (_, bestLagIdx, confidence) = autocorrelate(onset: onset, lagMin: lagMin,
                                                         lagMax: lagMax, sampleRate: sampleRate)
        let actualLag    = bestLagIdx + lagMin
        let estimatedBpm = 60.0 * sampleRate / (Double(actualLag) * Double(hopSize))

        // Stage 3: DP beat sequence
        let period = Int((sampleRate / (estimatedBpm / 60.0) / Double(hopSize)).rounded())
        let beats  = trackBeats(onset: onset, period: period, sampleRate: sampleRate)

        let (beatsPerBar, bars): (Int, [Double]) = confidence >= 0.3
            ? detectMeter(onset: onset, beatPeriod: period, beats: beats, sampleRate: sampleRate)
            : (0, [])

        return BpmResult(bpm: estimatedBpm, confidence: confidence, beats: beats,
                         beatsPerBar: beatsPerBar, bars: bars)
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
    ) -> ([Float], Int, Double) {  // returns (weightedNormalizedAc, bestLagIdx, confidence)
        let n     = onset.count
        let nLags = lagMax - lagMin + 1
        var ac    = [Float](repeating: 0, count: nLags)
        var rawAc = [Double](repeating: 0, count: nLags)

        for i in 0 ..< nLags {
            let lag   = lagMin + i
            let count = n - lag
            guard count > 0 else { continue }
            var sum: Double = 0
            for t in 0 ..< count { sum += Double(onset[t]) * Double(onset[t + lag]) }
            let normalized = sum / Double(count)
            rawAc[i] = normalized
            let bpm = 60.0 * sampleRate / (Double(lag) * Double(hopSize))
            let z   = (bpm - tempoPriorMean) / tempoPriorSigma
            ac[i]   = Float(normalized * exp(-0.5 * z * z))
        }

        let maxAc = ac.max() ?? 0
        if maxAc > 0 { for i in ac.indices { ac[i] /= maxAc } }
        let bestIdx = ac.indices.max(by: { ac[$0] < ac[$1] }) ?? 0

        // Confidence: ratio of raw autocorrelation at best lag to zero-lag energy
        var zeroLagSum: Double = 0
        for t in 0 ..< n { zeroLagSum += Double(onset[t]) * Double(onset[t]) }
        let ac0        = zeroLagSum / Double(n)
        let confidence = ac0 > 0 ? min(1.0, rawAc[bestIdx] / ac0) : 0.0

        return (ac, bestIdx, confidence)
    }

    private static func trackBeats(onset: [Float], period: Int, sampleRate: Double) -> [Double] {
        let n = onset.count
        guard period >= 2, n >= period else { return [] }

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
            beatFrames.append(t)
            t = prev[t]
        }
        beatFrames.reverse()

        let microFadeSeconds = 0.005
        return beatFrames
            .map { Double($0) * Double(hopSize) / sampleRate }
            .filter { $0 >= microFadeSeconds }
    }

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
}
