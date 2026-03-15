import AVFoundation

// MARK: - CrossfadeRamp

/// Pre-computed equal-power crossfade gain ramps.
///
/// Equal-power crossfade preserves perceived loudness throughout the transition:
/// `cos²(θ) + sin²(θ) = 1` ensures that the combined power of the two
/// signals equals 1.0 at every point in the ramp.
///
/// All properties are read-only after initialization — the struct is immutable
/// and safe to share across threads after construction.
public struct CrossfadeRamp {

    /// Fade-out gain values applied to the tail of the primary buffer.
    /// Computed as `cos(t * π/2)` where `t` runs from 0 to 1.
    /// Starts at 1.0 (full amplitude) and decreases to 0.0 (silence).
    public let fadeOut: [Float]

    /// Fade-in gain values applied to the head of the secondary buffer.
    /// Computed as `sin(t * π/2)` where `t` runs from 0 to 1.
    /// Starts at 0.0 (silence) and increases to 1.0 (full amplitude).
    public let fadeIn: [Float]

    /// Number of frames in each ramp. Both `fadeOut` and `fadeIn` have this count.
    public let frameCount: Int

    /// Builds equal-power crossfade ramps for the given duration and sample rate.
    ///
    /// Pre-computes both ramps entirely at construction time.
    /// Construction is O(n) in `frameCount`; lookups are O(1).
    ///
    /// - Parameters:
    ///   - duration: The crossfade duration in seconds. Must be > 0.
    ///   - sampleRate: The audio sample rate in Hz (e.g. 44100.0).
    public init(duration: TimeInterval, sampleRate: Double) {
        let frames = max(1, Int(duration * sampleRate))
        var out = [Float](repeating: 0, count: frames)
        var fadeInArr = [Float](repeating: 0, count: frames)

        for i in 0..<frames {
            // t progresses from 0.0 to 1.0 over the ramp.
            let t = Float(i) / Float(frames)
            // cos(t * π/2): 1.0 at t=0, 0.0 at t=1 — the fade-out curve.
            out[i] = Foundation.cos(t * .pi / 2.0)
            // sin(t * π/2): 0.0 at t=0, 1.0 at t=1 — the fade-in curve.
            fadeInArr[i] = Foundation.sin(t * .pi / 2.0)
        }

        self.fadeOut = out
        self.fadeIn  = fadeInArr
        self.frameCount = frames
    }
}

// MARK: - CrossfadeEngine

/// Applies pre-computed equal-power crossfade ramps to two PCM buffers in-place.
///
/// This type is a namespace (case-less enum) — it has no instances.
///
/// ## Usage
///
/// ```swift
/// let ramp = CrossfadeRamp(duration: 0.1, sampleRate: 44100.0)
/// CrossfadeEngine.apply(ramp: ramp, primary: tailBuffer, secondary: headBuffer)
/// // tailBuffer tail is now faded out; headBuffer head is now faded in.
/// ```
public enum CrossfadeEngine {

    /// Applies the fadeOut ramp to the **tail** of `primary` and the fadeIn ramp
    /// to the **head** of `secondary`, both in-place.
    ///
    /// The operation is:
    /// - `primary[primaryLength - rampFrames ... primaryLength-1] *= fadeOut`
    /// - `secondary[0 ... rampFrames-1] *= fadeIn`
    ///
    /// Both buffers must use the same `AVAudioFormat` (same channel count).
    /// If either buffer has fewer frames than `ramp.frameCount`, the overlap is
    /// clamped to the shorter buffer to prevent out-of-bounds access.
    ///
    /// - Parameters:
    ///   - ramp: The pre-computed equal-power crossfade ramp.
    ///   - primary: The buffer whose **tail** will be faded out.
    ///   - secondary: The buffer whose **head** will be faded in.
    public static func apply(
        ramp: CrossfadeRamp,
        primary: AVAudioPCMBuffer,
        secondary: AVAudioPCMBuffer
    ) {
        let channelCount = Int(primary.format.channelCount)
        // Clamp to the shorter buffer to prevent out-of-bounds access.
        let frames = min(ramp.frameCount, Int(primary.frameLength), Int(secondary.frameLength))
        guard frames > 0 else { return }

        let primaryLen = Int(primary.frameLength)

        guard let pData = primary.floatChannelData,
              let sData = secondary.floatChannelData else { return }

        for ch in 0..<channelCount {
            let p = pData[ch]
            let s = sData[ch]
            for i in 0..<frames {
                // Apply fade-out to the tail of primary:
                // primaryLen - frames + 0 is the first tail frame,
                // primaryLen - 1 is the last frame.
                p[primaryLen - frames + i] *= ramp.fadeOut[i]
                // Apply fade-in to the head of secondary (frame 0 onwards).
                s[i] *= ramp.fadeIn[i]
            }
        }
    }
}
