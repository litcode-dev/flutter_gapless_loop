#if os(iOS)
import AVFoundation

// MARK: - LoudnessAnalyser

/// EBU R128 / ITU-R BS.1770-4 integrated loudness analyser.
///
/// Applies the K-weighting pre-filter (two biquad stages) to the audio buffer,
/// then computes the mean-square energy and converts to LUFS.
///
/// ## K-weighting filter chain
///
/// Stage 1 — High-shelf (+4 dB above ~1682 Hz):
///   Pre-filters for the acoustic effect of the head (pinna diffraction).
///   Designed at 48 kHz and bilinear-transformed to the target sample rate.
///
/// Stage 2 — High-pass (2nd-order Butterworth, 38.13 Hz):
///   Removes DC and sub-bass that would otherwise inflate the measurement.
///
/// The exact coefficients match the ITU-R BS.1770-4 specification.
enum LoudnessAnalyser {

    // MARK: - Public API

    /// Computes the integrated loudness of [buffer] in LUFS (Loudness Units
    /// relative to Full Scale).
    ///
    /// Returns `-100.0` for silent or very short buffers.
    ///
    /// - Parameter buffer: The full decoded PCM buffer to analyse.
    /// - Returns: Integrated loudness in LUFS.
    static func analyse(buffer: AVAudioPCMBuffer) -> Double {
        guard let channelData = buffer.floatChannelData else { return -100.0 }

        let frameCount  = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let sampleRate   = buffer.format.sampleRate

        guard frameCount > 0 else { return -100.0 }

        // 1. Mix to mono by averaging channels.
        var mono = [Float](repeating: 0, count: frameCount)
        for ch in 0..<channelCount {
            let data = channelData[ch]
            for i in 0..<frameCount { mono[i] += data[i] }
        }
        let invCh = 1.0 / Float(channelCount)
        for i in 0..<frameCount { mono[i] *= invCh }

        // 2. Apply K-weighting filter chain in-place.
        applyKWeighting(signal: &mono, sampleRate: sampleRate)

        // 3. Compute mean square → LUFS.
        var sumSq: Double = 0
        for v in mono { sumSq += Double(v) * Double(v) }
        let meanSq = sumSq / Double(frameCount)
        guard meanSq > 0 else { return -100.0 }

        // LUFS = 10 × log10(mean_square) − 0.691  (BS.1770-4 offset)
        let lufs = 10.0 * Foundation.log10(meanSq) - 0.691
        return max(lufs, -100.0)
    }

    // MARK: - Private: K-weighting

    /// Applies the two-stage K-weighting biquad filter to [signal] in-place.
    private static func applyKWeighting(signal: inout [Float], sampleRate: Double) {
        let (s1b0, s1b1, s1b2, s1a1, s1a2) = stage1Coefficients(fs: sampleRate)
        let (s2b0, s2b1, s2b2, s2a1, s2a2) = stage2Coefficients(fs: sampleRate)

        applyBiquad(signal: &signal,
                    b0: s1b0, b1: s1b1, b2: s1b2, a1: s1a1, a2: s1a2)
        applyBiquad(signal: &signal,
                    b0: s2b0, b1: s2b1, b2: s2b2, a1: s2a1, a2: s2a2)
    }

    /// Direct-form II transposed biquad, processes [signal] in-place.
    private static func applyBiquad(
        signal: inout [Float],
        b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    ) {
        var z1: Double = 0, z2: Double = 0
        for i in 0..<signal.count {
            let x  = Double(signal[i])
            let y  = b0 * x + z1
            z1     = b1 * x - a1 * y + z2
            z2     = b2 * x - a2 * y
            signal[i] = Float(y)
        }
    }

    // MARK: - Stage 1: High-shelf (+4 dB @ ~1682 Hz)
    //
    // Derived from BS.1770-4 Annex 1, Table 1 (48 kHz reference coefficients
    // bilinear-transformed to arbitrary sample rates).
    //
    //  Vb = 10^(4/20) ≈ 1.58489  (shelf boost in linear gain)
    //  f0 = 1681.97 Hz
    //  Q  = 0.7072
    private static func stage1Coefficients(fs: Double) -> (Double, Double, Double, Double, Double) {
        let f0:  Double = 1681.97
        let Q:   Double = 0.7072
        let Vb:  Double = 1.58489   // 10^(4/20)
        let K    = Foundation.tan(Double.pi * f0 / fs)
        let norm = 1.0 / (1.0 + K / Q + K * K)
        let b0   = (Vb + Vb * K / Q + K * K) * norm
        let b1   = 2.0 * (K * K - Vb) * norm
        let b2   = (Vb - Vb * K / Q + K * K) * norm
        let a1   = 2.0 * (K * K - 1.0) * norm
        let a2   = (1.0 - K / Q + K * K) * norm
        return (b0, b1, b2, a1, a2)
    }

    // MARK: - Stage 2: High-pass, 2nd-order Butterworth (38.13 Hz)
    //
    //  f1 = 38.13 Hz
    //  Q  = 0.5003
    private static func stage2Coefficients(fs: Double) -> (Double, Double, Double, Double, Double) {
        let f1:  Double = 38.13
        let Q:   Double = 0.5003
        let K    = Foundation.tan(Double.pi * f1 / fs)
        let norm = 1.0 / (1.0 + K / Q + K * K)
        let b0   =  1.0 * norm
        let b1   = -2.0 * norm
        let b2   =  1.0 * norm
        let a1   = 2.0 * (K * K - 1.0) * norm
        let a2   = (1.0 - K / Q + K * K) * norm
        return (b0, b1, b2, a1, a2)
    }
}
#endif // os(iOS)
