#include "bpm_detector.h"
#include <cmath>
#include <algorithm>
#include <numeric>
#include <limits>

// ─── Constants ────────────────────────────────────────────────────────────────

static constexpr int    kFrameSize         = 512;
static constexpr int    kHopSize           = 256;
static constexpr double kMinBpm            = 60.0;
static constexpr double kMaxBpm            = 180.0;
static constexpr double kTempoPriorMean    = 120.0;
static constexpr double kTempoPriorSigma   = 30.0;
static constexpr double kDpLambda          = 100.0;
static constexpr double kMinDurationSecs   = 2.0;
static constexpr double kMicroFadeSecs     = 0.005;

// ─── Private Helpers ──────────────────────────────────────────────────────────

static std::vector<float> MixToMono(
    const float* pcm, int totalFrames, int channelCount)
{
    std::vector<float> mono(totalFrames);
    if (channelCount == 1) {
        std::copy(pcm, pcm + totalFrames, mono.begin());
        return mono;
    }
    for (int f = 0; f < totalFrames; ++f) {
        float sum = 0.f;
        for (int ch = 0; ch < channelCount; ++ch)
            sum += pcm[f * channelCount + ch];
        mono[f] = sum / static_cast<float>(channelCount);
    }
    return mono;
}

static std::vector<float> ComputeOnsetStrength(
    const std::vector<float>& mono, int frameCount)
{
    const int nFrames = (frameCount - kFrameSize) / kHopSize + 1;
    std::vector<float> rms(nFrames, 0.f);
    for (int f = 0; f < nFrames; ++f) {
        const int start = f * kHopSize;
        float sumSq = 0.f;
        for (int i = start; i < start + kFrameSize; ++i) {
            sumSq += mono[i] * mono[i];
        }
        rms[f] = std::sqrt(sumSq / static_cast<float>(kFrameSize));
    }
    std::vector<float> onset(nFrames, 0.f);
    for (int f = 1; f < nFrames; ++f)
        onset[f] = std::max(0.f, rms[f] - rms[f - 1]);
    return onset;
}

struct AutocorrelateResult {
    std::vector<float> ac;
    int    bestIdx    = 0;
    double confidence = 0.0;
};

static AutocorrelateResult Autocorrelate(
    const std::vector<float>& onset, int lagMin, int lagMax, double sampleRate)
{
    const int n     = static_cast<int>(onset.size());
    const int nLags = lagMax - lagMin + 1;
    std::vector<float>  ac(nLags, 0.f);
    std::vector<double> rawAc(nLags, 0.0);

    for (int i = 0; i < nLags; ++i) {
        const int lag   = lagMin + i;
        const int count = n - lag;
        if (count <= 0) continue;
        double sum = 0.0;
        for (int t = 0; t < count; ++t)
            sum += static_cast<double>(onset[t]) * static_cast<double>(onset[t + lag]);
        const double normalized = sum / static_cast<double>(count);
        rawAc[i] = normalized;
        const double bpm = 60.0 * sampleRate / (static_cast<double>(lag) * kHopSize);
        const double z   = (bpm - kTempoPriorMean) / kTempoPriorSigma;
        ac[i] = static_cast<float>(normalized * std::exp(-0.5 * z * z));
    }

    const float maxAc = *std::max_element(ac.begin(), ac.end());
    if (maxAc > 0.f)
        for (auto& v : ac) v /= maxAc;

    int bestIdx = 0;
    for (int i = 1; i < nLags; ++i)
        if (ac[i] > ac[bestIdx]) bestIdx = i;

    double zeroLagSum = 0.0;
    for (auto v : onset) zeroLagSum += static_cast<double>(v) * v;
    const double ac0 = zeroLagSum / static_cast<double>(n);
    const double confidence = (ac0 > 0.0)
        ? std::min(1.0, rawAc[bestIdx] / ac0) : 0.0;

    return {std::move(ac), bestIdx, confidence};
}

static std::vector<double> TrackBeats(
    const std::vector<float>& onset, int period, double sampleRate)
{
    const int n = static_cast<int>(onset.size());
    if (period < 2 || n < period) return {};

    const float kNegInf = -std::numeric_limits<float>::max();
    std::vector<float> score(n, kNegInf);
    std::vector<int>   prev(n, -1);

    const int initLen = std::min(period * 2, n);
    for (int t = 0; t < initLen; ++t) score[t] = onset[t];

    const int halfPeriod  = period / 2;
    const int twoPeriod   = period * 2;
    for (int t = period; t < n; ++t) {
        for (int d = halfPeriod; d <= twoPeriod; ++d) {
            const int b = t - d;
            if (b < 0 || score[b] == kNegInf) continue;
            const double logR    = std::log(static_cast<double>(d) / period);
            const float  penalty = static_cast<float>(kDpLambda * logR * logR);
            const float  cand    = score[b] + onset[t] - penalty;
            if (cand > score[t]) { score[t] = cand; prev[t] = b; }
        }
    }

    int best = n - 1;
    for (int t = std::max(0, n - period); t < n; ++t)
        if (score[t] > score[best]) best = t;

    std::vector<int> beatFrames;
    for (int t = best; t >= 0 && score[t] != kNegInf; t = prev[t])
        beatFrames.push_back(t);
    std::reverse(beatFrames.begin(), beatFrames.end());

    std::vector<double> beats;
    beats.reserve(beatFrames.size());
    for (int f : beatFrames) {
        const double ts = static_cast<double>(f) * kHopSize / sampleRate;
        if (ts >= kMicroFadeSecs) beats.push_back(ts);
    }
    return beats;
}

static std::pair<int, std::vector<double>> DetectMeter(
    const std::vector<float>& onset, int beatPeriod,
    const std::vector<double>& beats, double sampleRate)
{
    static const int kCandidates[] = {2, 3, 4, 6, 7};
    const double priorMean  = 4.0;
    const double priorSigma = 1.5;
    const int    n          = static_cast<int>(onset.size());

    int    bestMeter = 0;
    double bestScore = -std::numeric_limits<double>::max();

    for (int m : kCandidates) {
        const int lag = m * beatPeriod;
        if (lag >= n) continue;
        double sum = 0.0;
        for (int t = 0; t < n - lag; ++t)
            sum += static_cast<double>(onset[t]) * onset[t + lag];
        const double ac = sum / static_cast<double>(n - lag);
        const double z  = (static_cast<double>(m) - priorMean) / priorSigma;
        const double w  = ac * std::exp(-0.5 * z * z);
        if (w > bestScore) { bestScore = w; bestMeter = m; }
    }

    if (bestMeter == 0 || static_cast<int>(beats.size()) < bestMeter)
        return {0, {}};

    // Find strongest-onset beat as downbeat anchor.
    int    strongestIdx      = 0;
    float  strongestStrength = 0.f;
    for (int i = 0; i < static_cast<int>(beats.size()); ++i) {
        const int frame = std::min(
            static_cast<int>(beats[i] * sampleRate / kHopSize + 0.5), n - 1);
        if (onset[frame] > strongestStrength) {
            strongestStrength = onset[frame];
            strongestIdx      = i;
        }
    }

    std::vector<int> barIndices;
    for (int idx = strongestIdx; idx < static_cast<int>(beats.size()); idx += bestMeter)
        barIndices.push_back(idx);
    for (int idx = strongestIdx - bestMeter; idx >= 0; idx -= bestMeter)
        barIndices.insert(barIndices.begin(), idx);

    std::vector<double> bars;
    bars.reserve(barIndices.size());
    for (int idx : barIndices) bars.push_back(beats[idx]);

    return {bestMeter, std::move(bars)};
}

// ─── Public API ───────────────────────────────────────────────────────────────

BpmResult BpmDetector::Detect(
    const float* pcm, int totalFrames, int channelCount, double sampleRate)
{
    const double duration = static_cast<double>(totalFrames) / sampleRate;
    if (duration < kMinDurationSecs || !pcm)
        return {};

    const auto mono  = MixToMono(pcm, totalFrames, channelCount);
    auto       onset = ComputeOnsetStrength(mono, totalFrames);

    const float maxOnset = *std::max_element(onset.begin(), onset.end());
    if (maxOnset <= 0.f) return {};
    for (auto& v : onset) v /= maxOnset;

    const int lagMin = std::max(
        1, static_cast<int>(sampleRate / (kMaxBpm / 60.0) / kHopSize));
    const int lagMax = std::min(
        static_cast<int>(onset.size()) / 2,
        static_cast<int>(std::ceil(sampleRate / (kMinBpm / 60.0) / kHopSize)));

    if (lagMin >= lagMax) return {};

    const auto ar     = Autocorrelate(onset, lagMin, lagMax, sampleRate);
    const int  actLag = ar.bestIdx + lagMin;
    const double estBpm = 60.0 * sampleRate / (static_cast<double>(actLag) * kHopSize);

    const int period = static_cast<int>(
        sampleRate / (estBpm / 60.0) / kHopSize + 0.5);
    const auto beats = TrackBeats(onset, period, sampleRate);

    auto [beatsPerBar, bars] = ar.confidence >= 0.3
        ? DetectMeter(onset, period, beats, sampleRate)
        : std::pair<int, std::vector<double>>{0, {}};

    BpmResult result;
    result.bpm        = estBpm;
    result.confidence = ar.confidence;
    result.beats      = beats;
    result.beatsPerBar = beatsPerBar;
    result.bars        = std::move(bars);
    return result;
}
