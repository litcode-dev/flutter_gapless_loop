#include "metronome_engine.h"
#include "audio_decoder.h"
#include <cmath>
#include <cstring>
#include <algorithm>
#include <chrono>
#include <unistd.h>
#include <glib.h>

static void PostToMainThread(std::function<void()> fn) {
    auto* cb = new std::function<void()>(std::move(fn));
    g_idle_add([](gpointer data) -> gboolean {
        auto& fn = *static_cast<std::function<void()>*>(data);
        fn();
        delete &fn;
        return G_SOURCE_REMOVE;
    }, cb);
}

MetronomeEngine::MetronomeEngine()
    : alive_(std::make_shared<std::atomic<bool>>(true)) {}

MetronomeEngine::~MetronomeEngine() { Dispose(); }

// ── DataCallback ─────────────────────────────────────────────────────────────

void MetronomeEngine::DataCallback(ma_device* pDev, void* pOut, const void*, ma_uint32 fc) {
    auto* self = static_cast<MetronomeEngine*>(pDev->pUserData);
    float* out = static_cast<float*>(pOut);
    const int ch = static_cast<int>(pDev->playback.channels);

    if (self->barPcm_.empty() || self->barFrames_ == 0) {
        memset(out, 0, fc * ch * sizeof(float));
        return;
    }

    const float* bar   = self->barPcm_.data();
    const auto   bFrames = static_cast<int64_t>(self->barFrames_);
    const float  vol   = self->volume_.load(std::memory_order_relaxed);
    const float  panL  = self->panLeft_.load(std::memory_order_relaxed);
    const float  panR  = self->panRight_.load(std::memory_order_relaxed);

    for (ma_uint32 i = 0; i < fc; ++i) {
        const int64_t frame = static_cast<int64_t>(self->readPos_) % bFrames;
        const int64_t next  = (frame + 1) % bFrames;
        const float   frac  = static_cast<float>(self->readPos_ - std::floor(self->readPos_));

        for (int c = 0; c < ch; ++c) {
            float s = bar[frame * ch + c] * (1.0f - frac) + bar[next * ch + c] * frac;
            s *= vol;
            if (ch == 2) s *= (c == 0 ? panL : panR);
            out[i * ch + c] = s;
        }
        self->readPos_ += 1.0;
        if (self->readPos_ >= static_cast<double>(bFrames))
            self->readPos_ -= static_cast<double>(bFrames);
    }
}

// ── DecodeBytes ───────────────────────────────────────────────────────────────

void MetronomeEngine::DecodeBytes(const std::vector<uint8_t>& data,
                                   const std::string& ext,
                                   std::vector<float>& out,
                                   uint32_t& sr, uint32_t& ch) {
    // Write to a temp file, decode via AudioDecoder::Decode, then delete.
    std::string tmp = "/tmp/fgl_metro_" + std::to_string(
        std::chrono::steady_clock::now().time_since_epoch().count()) + "." + ext;
    if (FILE* f = fopen(tmp.c_str(), "wb")) {
        fwrite(data.data(), 1, data.size(), f);
        fclose(f);
    }
    DecodedAudio decoded;
    if (AudioDecoder::Decode(tmp, decoded)) {
        out = std::move(decoded.pcm);
        sr  = decoded.sampleRate;
        ch  = decoded.channelCount;
    }
    unlink(tmp.c_str());
}

// ── MixInto ───────────────────────────────────────────────────────────────────

void MetronomeEngine::MixInto(std::vector<float>& dest, uint64_t destFrames,
                               const std::vector<float>& src, uint64_t srcFrames,
                               int channels, uint64_t offsetFrame) {
    const uint64_t copyFrames = std::min(srcFrames, destFrames - offsetFrame);
    for (uint64_t f = 0; f < copyFrames; ++f)
        for (int c = 0; c < channels; ++c)
            dest[(offsetFrame + f) * channels + c] += src[f * channels + c];
}

// ── BuildBarBuffer ────────────────────────────────────────────────────────────

bool MetronomeEngine::BuildBarBuffer() {
    if (clickPcm_.empty() || accentPcm_.empty()) return false;

    const double beatSecs = 60.0 / currentBpm_;
    const uint64_t beatFrames = static_cast<uint64_t>(beatSecs * clickSampleRate_);
    barFrames_ = beatFrames * static_cast<uint64_t>(currentBeatsPerBar_);

    barPcm_.assign(barFrames_ * clickChannels_, 0.0f);

    // Mix accent at frame 0
    const uint64_t accentFrames = accentPcm_.size() / clickChannels_;
    MixInto(barPcm_, barFrames_, accentPcm_, accentFrames, clickChannels_, 0);

    // Mix click at each beat position 1..N-1
    const uint64_t clickFrames = clickPcm_.size() / clickChannels_;
    for (int b = 1; b < currentBeatsPerBar_; ++b) {
        const uint64_t offset = static_cast<uint64_t>(b) * beatFrames;
        if (offset < barFrames_)
            MixInto(barPcm_, barFrames_, clickPcm_, clickFrames, clickChannels_, offset);
    }
    return true;
}

// ── Beat timer ────────────────────────────────────────────────────────────────

void MetronomeEngine::StartBeatTimer() {
    if (beatRunning_.exchange(true)) return;
    beatIndex_ = 0;
    beatThread_ = std::thread([this] {
        using Clock = std::chrono::steady_clock;
        const auto beatDuration = std::chrono::duration<double>(60.0 / currentBpm_);
        auto next = Clock::now() + beatDuration;

        while (beatRunning_.load()) {
            const int beat = beatIndex_;
            auto alive = alive_;
            auto* self = this;
            PostToMainThread([self, alive, beat] {
                if (!*alive) return;
                if (self->onBeatTick) self->onBeatTick(beat);
            });
            beatIndex_ = (beatIndex_ + 1) % currentBeatsPerBar_;
            std::this_thread::sleep_until(next);
            next += beatDuration;
        }
    });
}

void MetronomeEngine::StopBeatTimer() {
    beatRunning_.store(false);
    if (beatThread_.joinable()) beatThread_.join();
}

// ── RebuildAndRestart ─────────────────────────────────────────────────────────

void MetronomeEngine::RebuildAndRestart() {
    // Caller holds mutex_. Device must be stopped first.
    if (!isRunning_) return;
    if (deviceInited_) {
        ma_device_stop(&device_);
        ma_device_uninit(&device_);
        deviceInited_ = false;
    }
    StopBeatTimer();
    BuildBarBuffer();
    readPos_ = 0.0;

    ma_device_config cfg = ma_device_config_init(ma_device_type_playback);
    cfg.playback.format   = ma_format_f32;
    cfg.playback.channels = clickChannels_;
    cfg.sampleRate        = clickSampleRate_;
    cfg.dataCallback      = DataCallback;
    cfg.pUserData         = this;
    if (ma_device_init(nullptr, &cfg, &device_) == MA_SUCCESS) {
        deviceInited_ = true;
        ma_device_start(&device_);
    }
    StartBeatTimer();
}

// ── Public API ────────────────────────────────────────────────────────────────

void MetronomeEngine::Start(double bpm, int beatsPerBar,
                             const std::vector<uint8_t>& clickData,
                             const std::vector<uint8_t>& accentData,
                             const std::string& fileExtension) {
    std::lock_guard<std::mutex> lock(mutex_);
    currentBpm_         = bpm;
    currentBeatsPerBar_ = beatsPerBar;

    DecodeBytes(clickData,  fileExtension, clickPcm_,  clickSampleRate_, clickChannels_);
    DecodeBytes(accentData, fileExtension, accentPcm_, clickSampleRate_, clickChannels_);
    if (clickPcm_.empty()) {
        if (onError) onError("Failed to decode metronome click audio");
        return;
    }

    isRunning_ = true;
    RebuildAndRestart();
}

void MetronomeEngine::Stop() {
    std::lock_guard<std::mutex> lock(mutex_);
    isRunning_ = false;
    StopBeatTimer();
    if (deviceInited_) {
        ma_device_stop(&device_);
        ma_device_uninit(&device_);
        deviceInited_ = false;
    }
    readPos_ = 0.0;
}

void MetronomeEngine::SetBpm(double bpm) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!isRunning_) return;
    currentBpm_ = bpm;
    RebuildAndRestart();
}

void MetronomeEngine::SetBeatsPerBar(int bpb) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!isRunning_) return;
    currentBeatsPerBar_ = bpb;
    RebuildAndRestart();
}

void MetronomeEngine::SetVolume(float v) {
    volume_.store(std::clamp(v, 0.0f, 1.0f), std::memory_order_relaxed);
}

void MetronomeEngine::SetPan(float pan) {
    pan = std::clamp(pan, -1.0f, 1.0f);
    const float angle = (pan + 1.0f) * 0.5f * 3.14159265f * 0.5f;
    panLeft_.store(std::cos(angle),  std::memory_order_relaxed);
    panRight_.store(std::sin(angle), std::memory_order_relaxed);
}

void MetronomeEngine::Dispose() {
    *alive_ = false;
    Stop();
}
