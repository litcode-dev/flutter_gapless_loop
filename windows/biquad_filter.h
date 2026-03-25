#pragma once
#include <cmath>
#include <algorithm>
#include <vector>

// ─── BiquadFilter ─────────────────────────────────────────────────────────────
//
// Single second-order IIR (biquad) filter using Direct Form II Transposed.
// Coefficient formulas from the Audio EQ Cookbook (R. Bristow-Johnson).
//
// One instance processes one audio channel. For stereo, create two instances
// and keep them synchronised (same coefficients, independent state).
//
// Not thread-safe — call exclusively from the audio processing thread.

class BiquadFilter {
public:
    BiquadFilter() { SetBypass(); }

    // ── Filter types ─────────────────────────────────────────────────────────

    void SetBypass() {
        b0_ = 1.f; b1_ = 0.f; b2_ = 0.f;
        a1_ = 0.f; a2_ = 0.f;
        Reset();
    }

    void SetLowShelf(float freqHz, float gainDb, int sampleRate) {
        if (gainDb == 0.f) { SetBypass(); return; }
        const float A   = std::pow(10.f, gainDb / 40.f);
        const float w0  = 2.f * kPi * freqHz / sampleRate;
        const float cw  = std::cos(w0);
        const float sw  = std::sin(w0);
        const float sqA = std::sqrt(A);
        // S=1 shelf: alpha = sin(w0)/sqrt(2)
        const float alp = sw * std::sqrt(2.f) / 2.f;

        const float b0n =    A * ((A+1.f) - (A-1.f)*cw + 2.f*sqA*alp);
        const float b1n = 2.f*A * ((A-1.f) - (A+1.f)*cw);
        const float b2n =    A * ((A+1.f) - (A-1.f)*cw - 2.f*sqA*alp);
        const float a0n =         (A+1.f) + (A-1.f)*cw + 2.f*sqA*alp;
        const float a1n =  -2.f * ((A-1.f) + (A+1.f)*cw);
        const float a2n =         (A+1.f) + (A-1.f)*cw - 2.f*sqA*alp;
        Set(b0n, b1n, b2n, a0n, a1n, a2n);
    }

    void SetHighShelf(float freqHz, float gainDb, int sampleRate) {
        if (gainDb == 0.f) { SetBypass(); return; }
        const float A   = std::pow(10.f, gainDb / 40.f);
        const float w0  = 2.f * kPi * freqHz / sampleRate;
        const float cw  = std::cos(w0);
        const float sw  = std::sin(w0);
        const float sqA = std::sqrt(A);
        const float alp = sw * std::sqrt(2.f) / 2.f;

        const float b0n =     A * ((A+1.f) + (A-1.f)*cw + 2.f*sqA*alp);
        const float b1n = -2.f*A * ((A-1.f) + (A+1.f)*cw);
        const float b2n =     A * ((A+1.f) + (A-1.f)*cw - 2.f*sqA*alp);
        const float a0n =          (A+1.f) - (A-1.f)*cw + 2.f*sqA*alp;
        const float a1n =   2.f * ((A-1.f) - (A+1.f)*cw);
        const float a2n =          (A+1.f) - (A-1.f)*cw - 2.f*sqA*alp;
        Set(b0n, b1n, b2n, a0n, a1n, a2n);
    }

    // Peaking EQ: bwOctaves = bandwidth in octaves
    void SetPeaking(float freqHz, float gainDb, float bwOctaves, int sampleRate) {
        if (gainDb == 0.f) { SetBypass(); return; }
        const float A   = std::pow(10.f, gainDb / 40.f);
        const float w0  = 2.f * kPi * freqHz / sampleRate;
        const float cw  = std::cos(w0);
        const float sw  = std::sin(w0);
        const float alp = sw * std::sinh(static_cast<float>(std::log(2.0) / 2.0)
                                          * bwOctaves * w0 / sw);

        const float b0n = 1.f + alp * A;
        const float b1n = -2.f * cw;
        const float b2n = 1.f - alp * A;
        const float a0n = 1.f + alp / A;
        const float a1n = -2.f * cw;
        const float a2n = 1.f - alp / A;
        Set(b0n, b1n, b2n, a0n, a1n, a2n);
    }

    void SetLowPass(float freqHz, float q, int sampleRate) {
        const float w0  = 2.f * kPi * freqHz / sampleRate;
        const float cw  = std::cos(w0);
        const float sw  = std::sin(w0);
        const float alp = sw / (2.f * q);

        const float b0n = (1.f - cw) / 2.f;
        const float b1n =  1.f - cw;
        const float b2n = (1.f - cw) / 2.f;
        const float a0n =  1.f + alp;
        const float a1n = -2.f * cw;
        const float a2n =  1.f - alp;
        Set(b0n, b1n, b2n, a0n, a1n, a2n);
    }

    void SetHighPass(float freqHz, float q, int sampleRate) {
        const float w0  = 2.f * kPi * freqHz / sampleRate;
        const float cw  = std::cos(w0);
        const float sw  = std::sin(w0);
        const float alp = sw / (2.f * q);

        const float b0n =  (1.f + cw) / 2.f;
        const float b1n = -(1.f + cw);
        const float b2n =  (1.f + cw) / 2.f;
        const float a0n =   1.f + alp;
        const float a1n =  -2.f * cw;
        const float a2n =   1.f - alp;
        Set(b0n, b1n, b2n, a0n, a1n, a2n);
    }

    // ── Processing ────────────────────────────────────────────────────────────

    inline float Process(float x) noexcept {
        const float y = b0_ * x + w1_;
        w1_ = b1_ * x - a1_ * y + w2_;
        w2_ = b2_ * x - a2_ * y;
        return y;
    }

    void Reset() noexcept { w1_ = 0.f; w2_ = 0.f; }

private:
    static constexpr float kPi = 3.14159265358979323846f;

    float b0_, b1_, b2_;
    float a1_, a2_;
    float w1_ = 0.f, w2_ = 0.f;

    void Set(float b0n, float b1n, float b2n, float a0n, float a1n, float a2n) {
        b0_ = b0n / a0n;
        b1_ = b1n / a0n;
        b2_ = b2n / a0n;
        a1_ = a1n / a0n;
        a2_ = a2n / a0n;
        Reset();
    }
};

// ─── BiquadFilterBank ─────────────────────────────────────────────────────────
//
// 4-stage serial filter bank (3 EQ bands + 1 cutoff).
// Processes interleaved PCM float buffers in-place.
// Stage layout: [0]=low shelf, [1]=peaking, [2]=high shelf, [3]=cutoff.

class BiquadFilterBank {
public:
    explicit BiquadFilterBank(int channelCount)
        : channelCount_(channelCount)
        , filters_(4 * channelCount)  // 4 stages × channelCount
    {}

    // ── Configuration ────────────────────────────────────────────────────────

    void SetLowShelf(float gainDb, int sampleRate) {
        for (int ch = 0; ch < channelCount_; ++ch)
            At(0, ch).SetLowShelf(80.f, gainDb, sampleRate);
    }

    void SetPeaking(float gainDb, int sampleRate) {
        for (int ch = 0; ch < channelCount_; ++ch)
            At(1, ch).SetPeaking(1000.f, gainDb, 1.0f, sampleRate);
    }

    void SetHighShelf(float gainDb, int sampleRate) {
        for (int ch = 0; ch < channelCount_; ++ch)
            At(2, ch).SetHighShelf(10000.f, gainDb, sampleRate);
    }

    // type: 0 = low-pass, 1 = high-pass
    void SetCutoff(float cutoffHz, int type, float resonance, int sampleRate) {
        cutoffHz  = std::max(20.f, std::min(20000.f, cutoffHz));
        resonance = std::max(0.1f, std::min(10.f, resonance));
        for (int ch = 0; ch < channelCount_; ++ch) {
            if (type == 1)
                At(3, ch).SetHighPass(cutoffHz, resonance, sampleRate);
            else
                At(3, ch).SetLowPass(cutoffHz, resonance, sampleRate);
        }
    }

    void BypassEq() {
        for (int stage = 0; stage < 3; ++stage)
            for (int ch = 0; ch < channelCount_; ++ch)
                At(stage, ch).SetBypass();
    }

    void BypassCutoff() {
        for (int ch = 0; ch < channelCount_; ++ch)
            At(3, ch).SetBypass();
    }

    void ResetState() {
        for (auto& f : filters_) f.Reset();
    }

    // ── Processing ────────────────────────────────────────────────────────────

    void Process(float* buffer, int numSamples) noexcept {
        for (int i = 0; i < numSamples; ++i) {
            const int ch = i % channelCount_;
            float s = buffer[i];
            s = At(0, ch).Process(s);
            s = At(1, ch).Process(s);
            s = At(2, ch).Process(s);
            s = At(3, ch).Process(s);
            buffer[i] = s;
        }
    }

private:
    int channelCount_;
    std::vector<BiquadFilter> filters_;

    BiquadFilter& At(int stage, int ch) {
        return filters_[stage * channelCount_ + ch];
    }
};
