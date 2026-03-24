#include "loop_audio_engine.h"
#include "audio_decoder.h"
#include "bpm_detector.h"
#include <glib.h>
#include <cmath>
#include <cstring>
#include <algorithm>
#include <thread>

// ── Helpers ───────────────────────────────────────────────────────────────────

// Post a lambda to the GLib main loop. Safe to call from any thread.
// The lambda MUST guard with alive_ before touching engine state.
static void PostToMainThread(std::function<void()> fn) {
    auto* cb = new std::function<void()>(std::move(fn));
    g_idle_add([](gpointer data) -> gboolean {
        auto& fn = *static_cast<std::function<void()>*>(data);
        fn();
        delete &fn;
        return G_SOURCE_REMOVE;
    }, cb);
}

// ── Construction / Destruction ────────────────────────────────────────────────

LoopAudioEngine::LoopAudioEngine()
    : alive_(std::make_shared<std::atomic<bool>>(true)) {}

LoopAudioEngine::~LoopAudioEngine() { Dispose(); }

// ── SetState ──────────────────────────────────────────────────────────────────

void LoopAudioEngine::SetState(EngineState s) {
    state_ = s;
    if (onStateChange) onStateChange(s);
}

// ── InitDevice / TeardownDevice ───────────────────────────────────────────────

void LoopAudioEngine::InitDevice() {
    if (deviceInited_) return;
    ma_device_config cfg = ma_device_config_init(ma_device_type_playback);
    cfg.playback.format      = ma_format_f32;
    cfg.playback.channels    = channelCount_;
    cfg.sampleRate           = sampleRate_;
    cfg.dataCallback         = DataCallback;
    cfg.notificationCallback = NotificationCallback;
    cfg.pUserData            = this;

    if (ma_device_init(nullptr, &cfg, &device_) != MA_SUCCESS) {
        if (onError) onError("Failed to initialise audio device");
        return;
    }
    deviceInited_ = true;
}

void LoopAudioEngine::TeardownDevice() {
    if (!deviceInited_) return;
    ma_device_stop(&device_);    // blocks until callback thread exits
    ma_device_uninit(&device_);
    deviceInited_ = false;
}

// ── DataCallback (audio thread — no locks, no allocations) ───────────────────

void LoopAudioEngine::DataCallback(ma_device* pDev, void* pOut,
                                    const void*, ma_uint32 frameCount) {
    // INVARIANT: all non-atomic fields read here (fullPcm_, loopStartFrame_,
    // loopEndFrame_, xfadeFrames_, xfadeOut_, xfadeIn_) must only be mutated
    // while the device is stopped (ma_device_stop called before write).
    auto* self = static_cast<LoopAudioEngine*>(pDev->pUserData);
    float* out = static_cast<float*>(pOut);
    const int ch = static_cast<int>(pDev->playback.channels);

    if (!self->playing_.load(std::memory_order_relaxed) || self->fullPcm_.empty()) {
        memset(out, 0, frameCount * ch * sizeof(float));
        return;
    }

    const float* pcm       = self->fullPcm_.data();
    const int64_t loopStart = static_cast<int64_t>(self->loopStartFrame_);
    const int64_t loopEnd   = static_cast<int64_t>(self->loopEndFrame_);
    const float   rate      = self->rate_.load(std::memory_order_relaxed);
    const float   vol       = self->volume_.load(std::memory_order_relaxed);
    const float   panL      = self->panLeft_.load(std::memory_order_relaxed);
    const float   panR      = self->panRight_.load(std::memory_order_relaxed);
    const int     xfFrames  = self->xfadeFrames_;

    float rmsAcc  = 0.0f;
    float peakAcc = 0.0f;

    for (ma_uint32 i = 0; i < frameCount; ++i) {
        // Wrap read position
        while (self->readPos_ >= static_cast<double>(loopEnd))
            self->readPos_ -= static_cast<double>(loopEnd - loopStart);
        if (self->readPos_ < static_cast<double>(loopStart))
            self->readPos_ = static_cast<double>(loopStart);

        const int64_t frame = static_cast<int64_t>(self->readPos_);
        const float   frac  = static_cast<float>(self->readPos_ - frame);

        // Next frame for interpolation (wraps within loop bounds)
        int64_t nextFrame = frame + 1;
        if (nextFrame >= loopEnd) nextFrame = loopStart;

        // Crossfade blend factor (0.0 = no blend, uses raw xfade ramps when > 0)
        float tailGain = 1.0f, headGain = 0.0f;
        int64_t headFrame = 0;
        int64_t headNext  = 0;
        if (xfFrames > 0 && frame >= loopEnd - xfFrames) {
            int xi = static_cast<int>(frame - (loopEnd - xfFrames));
            xi = std::min(xi, xfFrames - 1);
            tailGain  = self->xfadeOut_[xi];
            headGain  = self->xfadeIn_[xi];
            headFrame = loopStart + xi;
            headNext  = std::min(headFrame + 1, loopEnd - 1);
        }

        // Interpolate + blend + apply vol/pan
        for (int c = 0; c < ch; ++c) {
            const float s0 = pcm[frame    * ch + c];
            const float s1 = pcm[nextFrame * ch + c];
            float sample   = s0 + frac * (s1 - s0);

            if (headGain > 0.0f) {
                const float h0 = pcm[headFrame * ch + c];
                const float h1 = pcm[headNext  * ch + c];
                const float hs = h0 + frac * (h1 - h0);
                sample = sample * tailGain + hs * headGain;
            }

            sample *= vol;
            if (ch == 2) sample *= (c == 0 ? panL : panR);

            out[i * ch + c] = sample;
            rmsAcc  += sample * sample;
            peakAcc  = std::max(peakAcc, std::abs(sample));
        }

        self->readPos_ += rate;
    }

    // Amplitude emission (~20 Hz gate)
    const uint64_t prev = self->ampFrameCounter_.fetch_add(frameCount, std::memory_order_relaxed);
    if ((prev / kAmpEmitInterval) != ((prev + frameCount) / kAmpEmitInterval)) {
        const float rms  = std::sqrt(rmsAcc / static_cast<float>(frameCount * ch));
        const float peak = peakAcc;
        if (self->onAmplitude) {
            auto alive = self->alive_;
            auto* s    = self;
            PostToMainThread([s, alive, rms, peak] {
                if (!*alive) return;
                if (s->onAmplitude) s->onAmplitude(rms, peak);
            });
        }
    }
}

// ── NotificationCallback ──────────────────────────────────────────────────────

void LoopAudioEngine::NotificationCallback(const ma_device_notification* n) {
    auto* self = static_cast<LoopAudioEngine*>(n->pDevice->pUserData);
    if (n->type == ma_device_notification_type_rerouted) {
        // MUST NOT call ma_device_uninit/stop inline — deadlock.
        auto alive = self->alive_;
        auto* s = self;
        PostToMainThread([s, alive] {
            if (!*alive) return;
            s->HandleReroute();
        });
    }
}

// ── HandleReroute (main thread) ────────────────────────────────────────────────

void LoopAudioEngine::HandleReroute() {
    std::lock_guard<std::mutex> lock(stateMutex_);
    wasPlayingBeforeReroute_ = (state_ == EngineState::playing);
    TeardownDevice();
    InitDevice();
    if (wasPlayingBeforeReroute_ && deviceInited_) {
        playing_.store(true, std::memory_order_relaxed);
        ma_device_start(&device_);
        SetState(EngineState::playing);
    }
    if (onRouteChange) onRouteChange("unknown");
}

// ── LoadFile ──────────────────────────────────────────────────────────────────

bool LoopAudioEngine::LoadFile(const std::string& path) {
    StopBpmThread();
    {
        std::lock_guard<std::mutex> lock(stateMutex_);
        TeardownDevice();
        SetState(EngineState::loading);
    }

    // Decode on a background thread; commit result on main thread via callback.
    auto alive = alive_;
    auto* self = this;
    std::thread([self, alive, path] {
        DecodedAudio decoded;
        bool ok = AudioDecoder::Decode(path, decoded);
        PostToMainThread([self, alive, ok, decoded = std::move(decoded)]() mutable {
            if (!*alive) return;
            std::lock_guard<std::mutex> lock(self->stateMutex_);
            if (!ok) {
                self->SetState(EngineState::error);
                if (self->onError) self->onError("Failed to decode: " + std::string(""));
                return;
            }
            self->fullPcm_      = std::move(decoded.pcm);
            self->sampleRate_   = decoded.sampleRate;
            self->channelCount_ = decoded.channelCount;
            self->totalFrames_  = decoded.totalFrames;
            self->loopStartFrame_ = 0;
            self->loopEndFrame_   = decoded.totalFrames;
            self->fileDuration_   = static_cast<double>(decoded.totalFrames) / decoded.sampleRate;
            self->readPos_        = 0.0;
            self->xfadeFrames_    = 0;
            self->crossfadeDuration_ = 0.0;
            self->InitDevice();
            self->SetState(EngineState::ready);
            self->StartBpmThread();
        });
    }).detach();
    return true;
}

bool LoopAudioEngine::LoadUrl(const std::string& url) {
    StopBpmThread();
    {
        std::lock_guard<std::mutex> lock(stateMutex_);
        TeardownDevice();
        SetState(EngineState::loading);
    }
    auto alive = alive_;
    auto* self = this;
    std::thread([self, alive, url] {
        DecodedAudio decoded;
        bool ok = AudioDecoder::DecodeUrl(url, decoded);
        PostToMainThread([self, alive, ok, decoded = std::move(decoded)]() mutable {
            if (!*alive) return;
            std::lock_guard<std::mutex> lock(self->stateMutex_);
            if (!ok) {
                self->SetState(EngineState::error);
                if (self->onError) self->onError("URL download or decode failed");
                return;
            }
            self->fullPcm_      = std::move(decoded.pcm);
            self->sampleRate_   = decoded.sampleRate;
            self->channelCount_ = decoded.channelCount;
            self->totalFrames_  = decoded.totalFrames;
            self->loopStartFrame_ = 0;
            self->loopEndFrame_   = decoded.totalFrames;
            self->fileDuration_   = static_cast<double>(decoded.totalFrames) / decoded.sampleRate;
            self->readPos_        = 0.0;
            self->xfadeFrames_    = 0;
            self->crossfadeDuration_ = 0.0;
            self->InitDevice();
            self->SetState(EngineState::ready);
            self->StartBpmThread();
        });
    }).detach();
    return true;
}

// ── Playback control ──────────────────────────────────────────────────────────

void LoopAudioEngine::Play() {
    std::lock_guard<std::mutex> lock(stateMutex_);
    if (!deviceInited_ || fullPcm_.empty()) return;
    readPos_ = static_cast<double>(loopStartFrame_);
    playing_.store(true, std::memory_order_relaxed);
    ma_device_start(&device_);
    SetState(EngineState::playing);
}

void LoopAudioEngine::Pause() {
    std::lock_guard<std::mutex> lock(stateMutex_);
    if (state_ != EngineState::playing) return;
    playing_.store(false, std::memory_order_relaxed);
    ma_device_stop(&device_);
    SetState(EngineState::paused);
}

void LoopAudioEngine::Resume() {
    std::lock_guard<std::mutex> lock(stateMutex_);
    if (state_ != EngineState::paused) return;
    playing_.store(true, std::memory_order_relaxed);
    ma_device_start(&device_);
    SetState(EngineState::playing);
}

void LoopAudioEngine::Stop() {
    std::lock_guard<std::mutex> lock(stateMutex_);
    if (state_ == EngineState::idle || state_ == EngineState::loading) return;
    playing_.store(false, std::memory_order_relaxed);
    if (deviceInited_) ma_device_stop(&device_);
    readPos_ = static_cast<double>(loopStartFrame_);
    SetState(EngineState::stopped);
}

// ── Loop region ───────────────────────────────────────────────────────────────

bool LoopAudioEngine::SetLoopRegion(double startSecs, double endSecs) {
    std::lock_guard<std::mutex> lock(stateMutex_);
    if (fullPcm_.empty()) return false;
    const uint64_t s = static_cast<uint64_t>(startSecs * sampleRate_);
    const uint64_t e = static_cast<uint64_t>(endSecs   * sampleRate_);
    if (s >= e || e > totalFrames_) return false;
    // Stop device before mutating xfade ramps — DataCallback reads them lock-free.
    const bool wasPlaying = (state_ == EngineState::playing);
    if (deviceInited_) ma_device_stop(&device_);
    loopStartFrame_ = s;
    loopEndFrame_   = e;
    RebuildXfadeRamps();
    if (wasPlaying && deviceInited_) ma_device_start(&device_);
    return true;
}

// ── Crossfade ─────────────────────────────────────────────────────────────────

void LoopAudioEngine::SetCrossfadeDuration(double durationSecs) {
    std::lock_guard<std::mutex> lock(stateMutex_);
    // Stop device before rebuilding ramps — DataCallback reads them lock-free.
    const bool wasPlaying = (state_ == EngineState::playing);
    if (deviceInited_) ma_device_stop(&device_);
    crossfadeDuration_ = durationSecs;
    RebuildXfadeRamps();
    if (wasPlaying && deviceInited_) ma_device_start(&device_);
}

void LoopAudioEngine::RebuildXfadeRamps() {
    // Called with stateMutex_ held. Device must be stopped before calling if playing.
    if (crossfadeDuration_ <= 0.0) {
        xfadeFrames_ = 0;
        xfadeOut_.clear();
        xfadeIn_.clear();
        return;
    }
    const int64_t loopLen = static_cast<int64_t>(loopEndFrame_ - loopStartFrame_);
    int frames = static_cast<int>(crossfadeDuration_ * sampleRate_);
    frames = std::min(frames, static_cast<int>(loopLen / 2));
    if (frames <= 0) { xfadeFrames_ = 0; return; }
    xfadeFrames_ = frames;
    xfadeOut_.resize(frames);
    xfadeIn_.resize(frames);
    for (int i = 0; i < frames; ++i) {
        const float t = static_cast<float>(i) / static_cast<float>(frames);
        xfadeOut_[i] = std::cos(t * 3.14159265f * 0.5f);
        xfadeIn_[i]  = std::sin(t * 3.14159265f * 0.5f);
    }
}

// ── Volume / Pan / Rate ───────────────────────────────────────────────────────

void LoopAudioEngine::SetVolume(float v) {
    volume_.store(std::clamp(v, 0.0f, 1.0f), std::memory_order_relaxed);
}

void LoopAudioEngine::SetPan(float pan) {
    pan = std::clamp(pan, -1.0f, 1.0f);
    // Equal-power pan
    const float angle = (pan + 1.0f) * 0.5f * 3.14159265f * 0.5f;
    panLeft_.store(std::cos(angle),  std::memory_order_relaxed);
    panRight_.store(std::sin(angle), std::memory_order_relaxed);
}

void LoopAudioEngine::SetPlaybackRate(float r) {
    rate_.store(std::clamp(r, 0.25f, 4.0f), std::memory_order_relaxed);
}

// ── Seek ──────────────────────────────────────────────────────────────────────

bool LoopAudioEngine::Seek(double positionSecs) {
    std::lock_guard<std::mutex> lock(stateMutex_);
    if (fullPcm_.empty()) return false;
    const double newPos = std::clamp(positionSecs * sampleRate_,
                                     static_cast<double>(loopStartFrame_),
                                     static_cast<double>(loopEndFrame_ - 1));
    // Stop device before writing readPos_ — DataCallback reads it lock-free.
    const bool wasPlaying = (state_ == EngineState::playing);
    if (deviceInited_ && wasPlaying) ma_device_stop(&device_);
    readPos_ = newPos;
    if (deviceInited_ && wasPlaying) ma_device_start(&device_);
    return true;
}

// ── Duration / Position ───────────────────────────────────────────────────────

double LoopAudioEngine::GetDuration() const {
    std::lock_guard<std::mutex> lock(stateMutex_);
    return fileDuration_;
}

double LoopAudioEngine::GetCurrentPosition() const {
    // readPos_ is written by the audio callback without a lock (lock-free hot path).
    // This read may race with the callback — the returned value is best-effort and
    // may be slightly stale. Acquiring stateMutex_ only prevents concurrent
    // main-thread calls from racing each other, not the callback.
    return readPos_ / static_cast<double>(sampleRate_ > 0 ? sampleRate_ : 44100);
}

// ── BPM thread ────────────────────────────────────────────────────────────────

void LoopAudioEngine::StartBpmThread() {
    if (bpmRunning_.exchange(true)) return;
    bpmThread_ = std::thread([this] {
        // Snapshot PCM (thread-safe: fullPcm_ is not mutated after LoadFile commits)
        const float* pcm   = fullPcm_.data();
        const auto   frames = static_cast<int>(totalFrames_);
        const auto   ch     = static_cast<int>(channelCount_);
        const double sr     = static_cast<double>(sampleRate_);

        if (!bpmRunning_.load()) return;
        BpmResult result = BpmDetector::Detect(pcm, frames, ch, sr);

        if (!bpmRunning_.load()) return;
        auto alive = alive_;
        auto* self = this;
        PostToMainThread([self, alive, result] {
            if (!*alive) return;
            if (self->onBpmDetected) self->onBpmDetected(result);
        });
        bpmRunning_.store(false);
    });
    bpmThread_.detach();
}

void LoopAudioEngine::StopBpmThread() {
    bpmRunning_.store(false);
    // Thread is detached; setting the flag causes it to return early.
}

// ── Dispose ───────────────────────────────────────────────────────────────────

void LoopAudioEngine::Dispose() {
    *alive_ = false;     // Step 1: poison all pending g_idle_add lambdas
    StopBpmThread();
    {
        std::lock_guard<std::mutex> lock(stateMutex_);
        playing_.store(false, std::memory_order_relaxed);
        TeardownDevice();  // Step 2: joins audio thread
        SetState(EngineState::idle);
    }
    // Step 3: destructor of unique_ptr in plugin handler will free this object
}
