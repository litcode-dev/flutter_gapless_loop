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
