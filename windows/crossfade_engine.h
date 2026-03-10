#pragma once
#include <vector>
#include <cmath>
#include <algorithm>

// ─── CrossfadeRamp ────────────────────────────────────────────────────────────
//
// Pre-computed equal-power crossfade gain ramps.
//
// cos²(θ) + sin²(θ) = 1 guarantees that the combined power of the two signals
// equals 1.0 at every point in the ramp (equal-power crossfade).
//
// Immutable after construction — safe to share across threads.

struct CrossfadeRamp {
    std::vector<float> fadeOut;  ///< cos curve: 1.0 → 0.0. Applied to tail of primary.
    std::vector<float> fadeIn;   ///< sin curve: 0.0 → 1.0. Applied to head of secondary.
    int frameCount = 0;

    CrossfadeRamp() = default;

    /// Builds equal-power ramps for the given duration and sample rate.
    CrossfadeRamp(double duration, double sampleRate) {
        frameCount = std::max(1, static_cast<int>(duration * sampleRate));
        fadeOut.resize(frameCount);
        fadeIn.resize(frameCount);
        for (int i = 0; i < frameCount; ++i) {
            const float t = static_cast<float>(i) / static_cast<float>(frameCount);
            fadeOut[i] = std::cos(t * 3.14159265358979f * 0.5f);
            fadeIn[i]  = std::sin(t * 3.14159265358979f * 0.5f);
        }
    }
};

// ─── CrossfadeEngine ─────────────────────────────────────────────────────────
//
// Applies pre-computed equal-power ramps to two interleaved PCM buffers in-place.
// - primary:   tail is faded out (multiplied by fadeOut)
// - secondary: head is faded in  (multiplied by fadeIn)

namespace CrossfadeEngine {
    inline void Apply(
        const CrossfadeRamp& ramp,
        float* primary,   int primaryFrames,
        float* secondary, int secondaryFrames,
        int channelCount)
    {
        const int frames = std::min({ramp.frameCount, primaryFrames, secondaryFrames});
        if (frames <= 0) return;

        for (int i = 0; i < frames; ++i) {
            for (int ch = 0; ch < channelCount; ++ch) {
                primary  [(primaryFrames - frames + i) * channelCount + ch] *= ramp.fadeOut[i];
                secondary[i * channelCount + ch]                             *= ramp.fadeIn[i];
            }
        }
    }
}
