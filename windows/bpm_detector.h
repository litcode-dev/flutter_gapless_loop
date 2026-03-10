#pragma once
#include <vector>
#include <cstdint>

/// BPM detection result.
struct BpmResult {
    double bpm        = 0.0;   ///< Detected tempo in BPM. 0.0 if detection failed/skipped.
    double confidence = 0.0;   ///< Confidence in [0.0, 1.0]. >0.5 = reliable.
    std::vector<double> beats; ///< Beat timestamps in seconds from file start.
    int    beatsPerBar = 0;    ///< Time signature numerator. 0 if unknown.
    std::vector<double> bars;  ///< Bar start timestamps in seconds.
};

/// Ellis (2007) beat tracker: onset autocorrelation + DP beat sequence.
/// All functions are pure — no shared mutable state, fully thread-safe.
namespace BpmDetector {
    /// Detect BPM from interleaved float PCM.
    /// Returns bpm=0 if audio is shorter than 2 s or completely silent.
    BpmResult Detect(const float* pcm,
                     int          totalFrames,
                     int          channelCount,
                     double       sampleRate);
}
