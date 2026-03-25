#include "loop_audio_engine.h"
#include "audio_decoder.h"
#include "crossfade_engine.h"
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <wrl/client.h>
#include <cmath>
#include <algorithm>
#include <chrono>

using Microsoft::WRL::ComPtr;

// ─── DeviceNotifier (IMMNotificationClient) ───────────────────────────────────

class LoopAudioEngine::DeviceNotifier : public IMMNotificationClient {
    LONG              refCount_;
    LoopAudioEngine*  engine_;
public:
    explicit DeviceNotifier(LoopAudioEngine* eng) : refCount_(1), engine_(eng) {}

    // IUnknown
    ULONG   STDMETHODCALLTYPE AddRef()  override { return InterlockedIncrement(&refCount_); }
    ULONG   STDMETHODCALLTYPE Release() override {
        LONG r = InterlockedDecrement(&refCount_);
        if (r == 0) delete this;
        return r;
    }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** ppv) override {
        if (riid == __uuidof(IUnknown) || riid == __uuidof(IMMNotificationClient)) {
            *ppv = static_cast<IMMNotificationClient*>(this);
            AddRef();
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }

    // IMMNotificationClient — only care about default render device changes
    HRESULT STDMETHODCALLTYPE OnDefaultDeviceChanged(
        EDataFlow flow, ERole role, LPCWSTR) override
    {
        if (flow == eRender && role == eConsole && engine_)
            engine_->OnDeviceChanged();
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE OnDeviceAdded(LPCWSTR)                          override { return S_OK; }
    HRESULT STDMETHODCALLTYPE OnDeviceRemoved(LPCWSTR)                        override { return S_OK; }
    HRESULT STDMETHODCALLTYPE OnDeviceStateChanged(LPCWSTR, DWORD)            override { return S_OK; }
    HRESULT STDMETHODCALLTYPE OnPropertyValueChanged(LPCWSTR, const PROPERTYKEY) override { return S_OK; }
};

// ─── XfadeVoiceCallback ───────────────────────────────────────────────────────

// Minimal IXAudio2VoiceCallback that clears the pending flag when voiceB finishes.
namespace {
struct XfadeVoiceCallback : public IXAudio2VoiceCallback {
    std::atomic<bool>* pending;
    explicit XfadeVoiceCallback(std::atomic<bool>* p) : pending(p) {}

    void STDMETHODCALLTYPE OnBufferEnd(void*)                   override { *pending = false; }
    void STDMETHODCALLTYPE OnBufferStart(void*)                 override {}
    void STDMETHODCALLTYPE OnVoiceProcessingPassStart(UINT32)   override {}
    void STDMETHODCALLTYPE OnVoiceProcessingPassEnd()           override {}
    void STDMETHODCALLTYPE OnStreamEnd()                        override {}
    void STDMETHODCALLTYPE OnLoopEnd(void*)                     override {}
    void STDMETHODCALLTYPE OnVoiceError(void*, HRESULT)         override {}
};
} // namespace

// ─── PlaybackVoiceCallback ────────────────────────────────────────────────────

// Fires PostPlaybackComplete() when a one-shot buffer finishes on voiceA_.
void LoopAudioEngine::PlaybackVoiceCallback::OnBufferEnd(void* /*pBufferContext*/) {
    // Called on an XAudio2 internal thread. Must not block or join threads.
    if (engine && !engine->loop_) {
        engine->PostPlaybackComplete();
    }
}

// ─── Constructor / Destructor ────────────────────────────────────────────────

LoopAudioEngine::LoopAudioEngine() {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    AudioDecoder::Startup();
    InitDeviceNotifier();
}

LoopAudioEngine::~LoopAudioEngine() {
    Dispose();
    TeardownDeviceNotifier();
    AudioDecoder::Shutdown();
    CoUninitialize();
}

// ─── Public API ───────────────────────────────────────────────────────────────

bool LoopAudioEngine::LoadFile(const std::wstring& path) {
    SetState(EngineState::loading);
    StopMonitorThreads();
    StopBpmThread();

    // Stop any active playback before replacing buffers.
    if (voiceA_) { voiceA_->Stop(); voiceA_->FlushSourceBuffers(); }
    if (voiceB_) { voiceB_->Stop(); voiceB_->FlushSourceBuffers(); }

    DecodedAudio decoded;
    if (FAILED(AudioDecoder::Decode(path, decoded)) || decoded.pcm.empty()) {
        SetState(EngineState::error);
        if (onError) onError("LoopAudioEngine: failed to decode file");
        return false;
    }

    AudioDecoder::ApplyMicroFade(decoded.pcm, decoded.sampleRate, decoded.channelCount);

    {
        std::lock_guard<std::mutex> lock(stateMutex_);
        // Save raw (micro-faded, pre-EQ) PCM for re-processing when EQ changes.
        rawFullPcm_    = decoded.pcm;
        sampleRate_    = decoded.sampleRate;
        channelCount_  = decoded.channelCount;
        fileDuration_  = static_cast<double>(decoded.totalFrames) / sampleRate_;
        loopStart_     = 0.0;
        loopEnd_       = fileDuration_;
        rawLoopPcm_.clear();
        loopPcm_.clear();
        mainLoopPcm_.clear();
        xfadeHeadPcm_.clear();
        xfadeFrames_   = 0;
        mode_          = (crossfadeDuration_ > 0) ? PlaybackMode::C : PlaybackMode::A;

        // Apply EQ + cutoff to produce fullPcm_ from rawFullPcm_.
        fullPcm_ = rawFullPcm_;
        BiquadFilterBank bank(channelCount_);
        bank.SetLowShelf(eqLowGainDb_, sampleRate_);
        bank.SetPeaking(eqMidGainDb_, sampleRate_);
        bank.SetHighShelf(eqHighGainDb_, sampleRate_);
        if (cutoffHz_ > 0.f)
            bank.SetCutoff(cutoffHz_, cutoffType_, cutoffQ_, sampleRate_);
        bank.Process(fullPcm_.data(), static_cast<int>(fullPcm_.size()));
    }

    if (crossfadeDuration_ > 0)
        RebuildXfadeBuffers();

    // Re-create XAudio2 voices to match the new audio format.
    if (!InitXAudio2()) {
        SetState(EngineState::error);
        if (onError) onError("LoopAudioEngine: XAudio2 init failed");
        return false;
    }

    StartBpmThread();
    SetState(EngineState::ready);
    return true;
}

bool LoopAudioEngine::LoadUrl(const std::wstring& url) {
    SetState(EngineState::loading);
    StopMonitorThreads();
    StopBpmThread();

    if (voiceA_) { voiceA_->Stop(); voiceA_->FlushSourceBuffers(); }
    if (voiceB_) { voiceB_->Stop(); voiceB_->FlushSourceBuffers(); }

    DecodedAudio decoded;
    if (FAILED(AudioDecoder::DecodeUrl(url, decoded)) || decoded.pcm.empty()) {
        SetState(EngineState::error);
        if (onError) onError("LoopAudioEngine: failed to download/decode URL");
        return false;
    }

    AudioDecoder::ApplyMicroFade(decoded.pcm, decoded.sampleRate, decoded.channelCount);

    {
        std::lock_guard<std::mutex> lock(stateMutex_);
        rawFullPcm_   = decoded.pcm;
        sampleRate_   = decoded.sampleRate;
        channelCount_ = decoded.channelCount;
        fileDuration_ = static_cast<double>(decoded.totalFrames) / sampleRate_;
        loopStart_    = 0.0;
        loopEnd_      = fileDuration_;
        rawLoopPcm_.clear();
        loopPcm_.clear();
        mainLoopPcm_.clear();
        xfadeHeadPcm_.clear();
        xfadeFrames_  = 0;
        mode_         = (crossfadeDuration_ > 0) ? PlaybackMode::C : PlaybackMode::A;

        fullPcm_ = rawFullPcm_;
        BiquadFilterBank bank(channelCount_);
        bank.SetLowShelf(eqLowGainDb_, sampleRate_);
        bank.SetPeaking(eqMidGainDb_, sampleRate_);
        bank.SetHighShelf(eqHighGainDb_, sampleRate_);
        if (cutoffHz_ > 0.f)
            bank.SetCutoff(cutoffHz_, cutoffType_, cutoffQ_, sampleRate_);
        bank.Process(fullPcm_.data(), static_cast<int>(fullPcm_.size()));
    }

    if (crossfadeDuration_ > 0)
        RebuildXfadeBuffers();

    if (!InitXAudio2()) {
        SetState(EngineState::error);
        if (onError) onError("LoopAudioEngine: XAudio2 init failed after URL load");
        return false;
    }

    StartBpmThread();
    SetState(EngineState::ready);
    return true;
}

void LoopAudioEngine::Play(bool loop) {
    // Join any monitor threads lingering from a previous one-shot completion
    // before attempting to start new ones.
    StopMonitorThreads();

    std::lock_guard<std::mutex> lock(stateMutex_);
    if (state_ != EngineState::ready && state_ != EngineState::stopped) return;
    if (!voiceA_) return;
    loop_ = loop;

    SubmitLoopBuffer();
    voiceA_->Start();
    if (voiceB_ && (mode_ == PlaybackMode::C || mode_ == PlaybackMode::D))
        voiceB_->Start();

    SetState(EngineState::playing);
    StartMonitorThreads();
}

void LoopAudioEngine::Pause() {
    std::lock_guard<std::mutex> lock(stateMutex_);
    if (state_ != EngineState::playing) return;
    StopMonitorThreads();
    if (voiceA_) voiceA_->Stop();  // pause without flush
    if (voiceB_) voiceB_->Stop();
    SetState(EngineState::paused);
}

void LoopAudioEngine::Resume() {
    std::lock_guard<std::mutex> lock(stateMutex_);
    if (state_ != EngineState::paused) return;
    if (voiceA_) voiceA_->Start();
    if (voiceB_ && (mode_ == PlaybackMode::C || mode_ == PlaybackMode::D))
        voiceB_->Start();
    SetState(EngineState::playing);
    StartMonitorThreads();
}

void LoopAudioEngine::Stop() {
    StopMonitorThreads();
    {
        std::lock_guard<std::mutex> lock(stateMutex_);
        if (voiceA_) { voiceA_->Stop(); voiceA_->FlushSourceBuffers(); }
        if (voiceB_) { voiceB_->Stop(); voiceB_->FlushSourceBuffers(); }
        xfadeHeadPending_ = false;
        SetState(EngineState::stopped);
    }
}

bool LoopAudioEngine::SetLoopRegion(double startSecs, double endSecs) {
    std::lock_guard<std::mutex> lock(stateMutex_);
    if (rawFullPcm_.empty()) return false;
    if (startSecs < 0 || endSecs <= startSecs || endSecs > fileDuration_) return false;

    const int startFrame = static_cast<int>(startSecs * sampleRate_);
    const int endFrame   = static_cast<int>(endSecs   * sampleRate_);
    const int frames     = endFrame - startFrame;
    if (frames <= 0) return false;

    // Extract loop region from raw (pre-EQ) PCM and save for future EQ re-processing.
    rawLoopPcm_.assign(static_cast<size_t>(frames * channelCount_), 0.f);
    for (int i = 0; i < frames; ++i)
        for (uint32_t ch = 0; ch < channelCount_; ++ch)
            rawLoopPcm_[i * channelCount_ + ch] =
                rawFullPcm_[(startFrame + i) * channelCount_ + ch];

    AudioDecoder::ApplyMicroFade(rawLoopPcm_, sampleRate_, channelCount_);

    // Apply EQ + cutoff to produce loopPcm_.
    loopPcm_ = rawLoopPcm_;
    {
        BiquadFilterBank bank(channelCount_);
        bank.SetLowShelf(eqLowGainDb_, sampleRate_);
        bank.SetPeaking(eqMidGainDb_, sampleRate_);
        bank.SetHighShelf(eqHighGainDb_, sampleRate_);
        if (cutoffHz_ > 0.f)
            bank.SetCutoff(cutoffHz_, cutoffType_, cutoffQ_, sampleRate_);
        bank.Process(loopPcm_.data(), static_cast<int>(loopPcm_.size()));
    }

    loopStart_ = startSecs;
    loopEnd_   = endSecs;
    mode_      = (crossfadeDuration_ > 0) ? PlaybackMode::D : PlaybackMode::B;

    if (crossfadeDuration_ > 0)
        RebuildXfadeBuffers();

    if (state_ == EngineState::playing) {
        StopMonitorThreads();
        SubmitLoopBuffer();
        voiceA_->Start();
        StartMonitorThreads();
    }
    return true;
}

void LoopAudioEngine::SetCrossfadeDuration(double durationSecs) {
    std::lock_guard<std::mutex> lock(stateMutex_);
    crossfadeDuration_ = durationSecs;

    if (durationSecs > 0) {
        mode_ = loopPcm_.empty() ? PlaybackMode::C : PlaybackMode::D;
        // Lazy-create voiceB if we have a valid format.
        if (!voiceB_ && voiceA_ && xaudio2_) {
            WAVEFORMATEX wfx = {};
            wfx.wFormatTag      = WAVE_FORMAT_IEEE_FLOAT;
            wfx.nChannels       = static_cast<WORD>(channelCount_);
            wfx.nSamplesPerSec  = sampleRate_;
            wfx.wBitsPerSample  = 32;
            wfx.nBlockAlign     = wfx.nChannels * wfx.wBitsPerSample / 8;
            wfx.nAvgBytesPerSec = wfx.nSamplesPerSec * wfx.nBlockAlign;
            if (xfadeCallback_)
                xaudio2_->CreateSourceVoice(&voiceB_, &wfx, 0, XAUDIO2_MAX_FREQ_RATIO,
                                            xfadeCallback_);
            else
                xaudio2_->CreateSourceVoice(&voiceB_, &wfx, 0, XAUDIO2_MAX_FREQ_RATIO);
            if (voiceB_) {
                ApplyPanVolumeToVoice(voiceB_);
                voiceB_->Start();
            }
        }
        if (!ActivePcm().empty())
            RebuildXfadeBuffers();
    } else {
        mode_ = loopPcm_.empty() ? PlaybackMode::A : PlaybackMode::B;
        mainLoopPcm_.clear();
        xfadeHeadPcm_.clear();
        xfadeFrames_ = 0;
    }

    if (state_ == EngineState::playing) {
        StopMonitorThreads();
        SubmitLoopBuffer();
        voiceA_->Start();
        StartMonitorThreads();
    }
}

void LoopAudioEngine::SetVolume(float volume) {
    volume_ = std::max(0.f, std::min(1.f, volume));
    if (masterVoice_) masterVoice_->SetVolume(volume_);
}

void LoopAudioEngine::SetPan(float pan) {
    pan_ = std::max(-1.f, std::min(1.f, pan));
    ApplyPanVolume();
}

void LoopAudioEngine::SetPlaybackRate(float rate) {
    // XAudio2 SetFrequencyRatio changes speed and pitch together (no time-stretch).
    playbackRate_ = std::max(XAUDIO2_MIN_FREQ_RATIO, std::min(rate, XAUDIO2_MAX_FREQ_RATIO));
    if (voiceA_) voiceA_->SetFrequencyRatio(playbackRate_);
    if (voiceB_) voiceB_->SetFrequencyRatio(playbackRate_);
}

bool LoopAudioEngine::Seek(double positionSecs) {
    if (positionSecs < 0 || positionSecs >= fileDuration_) return false;

    std::lock_guard<std::mutex> lock(stateMutex_);
    if (state_ == EngineState::idle || state_ == EngineState::loading) return false;
    if (!voiceA_) return false;

    const bool wasPlaying = (state_ == EngineState::playing);

    // Clamp to the active region.
    const double clampedPos = std::max(ActiveStart(),
                                       std::min(positionSecs,
                                                ActiveStart() + static_cast<double>(ActiveFrames()) / sampleRate_ - 1.0 / sampleRate_));
    const int seekFrame    = static_cast<int>((clampedPos - ActiveStart()) * sampleRate_);
    const int activeFrames = ActiveFrames();
    const int remainFrames = activeFrames - seekFrame;

    StopMonitorThreads();
    xfadeHeadPending_ = false;

    const auto& submitPcm = (mode_ == PlaybackMode::C || mode_ == PlaybackMode::D)
                            ? mainLoopPcm_ : ActivePcm();

    voiceA_->Stop();
    voiceA_->FlushSourceBuffers();
    if (voiceB_) { voiceB_->Stop(); voiceB_->FlushSourceBuffers(); }

    // Buffer 1: one-shot from seekFrame to end of region.
    if (remainFrames > 0) {
        XAUDIO2_BUFFER buf1 = {};
        buf1.pAudioData = reinterpret_cast<const BYTE*>(submitPcm.data());
        buf1.AudioBytes = static_cast<UINT32>(submitPcm.size() * sizeof(float));
        buf1.PlayBegin  = static_cast<UINT32>(seekFrame);
        buf1.PlayLength = static_cast<UINT32>(remainFrames);
        buf1.LoopCount  = 0;
        voiceA_->SubmitSourceBuffer(&buf1);
    }

    // Buffer 2: the full loop, submitted immediately after buf1. Omitted when playing
    // one-shot (buf1 with LoopCount=0 fires OnBufferEnd at the end of buf1).
    if (loop_) {
        XAUDIO2_BUFFER buf2 = {};
        buf2.pAudioData = reinterpret_cast<const BYTE*>(submitPcm.data());
        buf2.AudioBytes = static_cast<UINT32>(submitPcm.size() * sizeof(float));
        buf2.LoopCount  = XAUDIO2_LOOP_INFINITE;
        voiceA_->SubmitSourceBuffer(&buf2);
    }

    if (wasPlaying) {
        voiceA_->Start();
        StartMonitorThreads();
    }
    return true;
}

double LoopAudioEngine::GetDuration() const {
    std::lock_guard<std::mutex> lock(stateMutex_);
    return fileDuration_;
}

double LoopAudioEngine::GetCurrentPosition() const {
    std::lock_guard<std::mutex> lock(stateMutex_);
    if (!voiceA_ || state_ == EngineState::idle || state_ == EngineState::loading)
        return 0.0;

    XAUDIO2_VOICE_STATE vs;
    voiceA_->GetState(&vs, 0);
    const int frames = ActiveFrames();
    if (frames == 0) return ActiveStart();

    const uint64_t loopFrames   = static_cast<uint64_t>(frames);
    const uint64_t posInLoop    = vs.SamplesPlayed % loopFrames;
    return ActiveStart() + static_cast<double>(posInLoop) / sampleRate_;
}

void LoopAudioEngine::Dispose() {
    StopMonitorThreads();
    StopBpmThread();
    TeardownXAudio2();
    SetState(EngineState::idle);
}

void LoopAudioEngine::OnDeviceChanged() {
    // Called from COM thread. Rebuild XAudio2 on the new default device.
    const bool wasPlaying = (state_ == EngineState::playing);
    StopMonitorThreads();

    TeardownXAudio2();
    if (InitXAudio2()) {
        if (wasPlaying) {
            SubmitLoopBuffer();
            voiceA_->Start();
            SetState(EngineState::playing);
            StartMonitorThreads();
        } else if (state_ == EngineState::paused) {
            SubmitLoopBuffer();
            // Voice paused: leave in paused state (caller can resume).
        }
    } else {
        SetState(EngineState::error);
    }

    if (onRouteChange) onRouteChange("headphonesUnplugged");
}

// ─── XAudio2 Graph ────────────────────────────────────────────────────────────

bool LoopAudioEngine::InitXAudio2() {
    TeardownXAudio2();

    delete xfadeCallback_;
    xfadeCallback_ = new XfadeVoiceCallback(&xfadeHeadPending_);

    HRESULT hr = XAudio2Create(&xaudio2_, 0, XAUDIO2_DEFAULT_PROCESSOR);
    if (FAILED(hr)) return false;

    hr = xaudio2_->CreateMasteringVoice(&masterVoice_);
    if (FAILED(hr)) return false;
    masterVoice_->SetVolume(volume_);

    WAVEFORMATEX wfx = {};
    wfx.wFormatTag      = WAVE_FORMAT_IEEE_FLOAT;
    wfx.nChannels       = static_cast<WORD>(channelCount_);
    wfx.nSamplesPerSec  = sampleRate_;
    wfx.wBitsPerSample  = 32;
    wfx.nBlockAlign     = wfx.nChannels * wfx.wBitsPerSample / 8;
    wfx.nAvgBytesPerSec = wfx.nSamplesPerSec * wfx.nBlockAlign;

    playbackCallback_.engine = this;
    hr = xaudio2_->CreateSourceVoice(&voiceA_, &wfx, 0, XAUDIO2_MAX_FREQ_RATIO,
                                     &playbackCallback_);
    if (FAILED(hr)) return false;

    if (crossfadeDuration_ > 0) {
        hr = xaudio2_->CreateSourceVoice(&voiceB_, &wfx, 0, XAUDIO2_MAX_FREQ_RATIO,
                                         xfadeCallback_);
        if (FAILED(hr)) { voiceB_ = nullptr; }
        else { voiceB_->Start(); }
    }

    ApplyPanVolume();
    voiceA_->SetFrequencyRatio(playbackRate_);
    return true;
}

void LoopAudioEngine::TeardownXAudio2() {
    if (voiceB_) { voiceB_->DestroyVoice(); voiceB_ = nullptr; }
    if (voiceA_) { voiceA_->DestroyVoice(); voiceA_ = nullptr; }
    if (masterVoice_) { masterVoice_->DestroyVoice(); masterVoice_ = nullptr; }
    if (xaudio2_) { xaudio2_->Release(); xaudio2_ = nullptr; }
    delete xfadeCallback_;
    xfadeCallback_ = nullptr;
}

// ─── Buffer Submission ────────────────────────────────────────────────────────

void LoopAudioEngine::SubmitLoopBuffer() {
    if (!voiceA_) return;

    const auto& pcm = (mode_ == PlaybackMode::C || mode_ == PlaybackMode::D)
                      ? mainLoopPcm_ : ActivePcm();
    if (pcm.empty()) return;

    voiceA_->Stop();
    voiceA_->FlushSourceBuffers();
    xfadeHeadPending_ = false;

    XAUDIO2_BUFFER buf = {};
    buf.pAudioData = reinterpret_cast<const BYTE*>(pcm.data());
    buf.AudioBytes = static_cast<UINT32>(pcm.size() * sizeof(float));
    buf.LoopCount  = loop_ ? XAUDIO2_LOOP_INFINITE : 0;
    voiceA_->SubmitSourceBuffer(&buf);
}

// ─── Crossfade Buffer Construction ───────────────────────────────────────────

void LoopAudioEngine::RebuildXfadeBuffers() {
    const auto& active = ActivePcm();
    const int   frames = ActiveFrames();
    if (frames == 0 || crossfadeDuration_ <= 0.0) return;

    const int maxXfade = frames / 2;
    xfadeFrames_ = std::min(maxXfade,
                            static_cast<int>(crossfadeDuration_ * sampleRate_));
    if (xfadeFrames_ <= 0) return;

    CrossfadeRamp ramp(static_cast<double>(xfadeFrames_) / sampleRate_, sampleRate_);

    // mainLoopPcm_: copy of active PCM with tail faded out.
    mainLoopPcm_ = active;
    for (int i = 0; i < xfadeFrames_; ++i) {
        const int tailIdx = frames - xfadeFrames_ + i;
        for (uint32_t ch = 0; ch < channelCount_; ++ch)
            mainLoopPcm_[tailIdx * channelCount_ + ch] *= ramp.fadeOut[i];
    }

    // xfadeHeadPcm_: first xfadeFrames_ frames with fadeIn applied.
    xfadeHeadPcm_.resize(static_cast<size_t>(xfadeFrames_) * channelCount_);
    for (int i = 0; i < xfadeFrames_; ++i)
        for (uint32_t ch = 0; ch < channelCount_; ++ch)
            xfadeHeadPcm_[i * channelCount_ + ch] =
                active[i * channelCount_ + ch] * ramp.fadeIn[i];
}

// ─── Monitor Threads ──────────────────────────────────────────────────────────

void LoopAudioEngine::StartMonitorThreads() {
    // Crossfade monitor (modes C/D only).
    if ((mode_ == PlaybackMode::C || mode_ == PlaybackMode::D)
        && voiceB_ && xfadeFrames_ > 0 && !crossfadeRunning_) {
        crossfadeRunning_ = true;
        crossfadeThread_ = std::thread([this]() {
            const int loopFrames  = ActiveFrames();
            const int triggerAt   = loopFrames - xfadeFrames_;
            uint64_t  lastCycle   = UINT64_MAX;

            while (crossfadeRunning_) {
                std::this_thread::sleep_for(std::chrono::milliseconds(5));
                if (!crossfadeRunning_ || !voiceA_ || !voiceB_) continue;

                XAUDIO2_VOICE_STATE vs;
                voiceA_->GetState(&vs, 0);
                const uint64_t sp    = vs.SamplesPlayed;
                const uint64_t cycle = sp / static_cast<uint64_t>(loopFrames);
                const int      pos   = static_cast<int>(sp % static_cast<uint64_t>(loopFrames));

                if (cycle != lastCycle && pos >= triggerAt && !xfadeHeadPending_) {
                    lastCycle         = cycle;
                    xfadeHeadPending_ = true;

                    XAUDIO2_BUFFER buf = {};
                    buf.pAudioData = reinterpret_cast<const BYTE*>(xfadeHeadPcm_.data());
                    buf.AudioBytes = static_cast<UINT32>(xfadeHeadPcm_.size() * sizeof(float));
                    buf.LoopCount  = 0;
                    voiceB_->SubmitSourceBuffer(&buf);
                }
            }
        });
    }

    // Amplitude monitor.
    if (!amplitudeRunning_) {
        amplitudeRunning_ = true;
        amplitudeThread_ = std::thread([this]() {
            while (amplitudeRunning_) {
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
                if (!amplitudeRunning_) break;
                if (!voiceA_ || !onAmplitude) continue;

                XAUDIO2_VOICE_STATE vs;
                voiceA_->GetState(&vs, 0);
                const auto& pcm     = ActivePcm();
                const int   frames  = ActiveFrames();
                if (frames == 0) continue;

                const int readFrames = std::min(1024, frames);
                const int startFrame = static_cast<int>(
                    vs.SamplesPlayed % static_cast<uint64_t>(frames));

                float sumSq = 0.f, peak = 0.f;
                for (int i = 0; i < readFrames; ++i) {
                    const int idx = (startFrame + i) % frames;
                    for (uint32_t ch = 0; ch < channelCount_; ++ch) {
                        const float s = pcm[idx * channelCount_ + ch];
                        sumSq += s * s;
                        const float a = s < 0.f ? -s : s;
                        if (a > peak) peak = a;
                    }
                }
                const float rms = std::sqrt(sumSq / static_cast<float>(readFrames * channelCount_));
                if (onAmplitude) onAmplitude(std::min(rms, 1.f), std::min(peak, 1.f));
            }
        });
    }
}

void LoopAudioEngine::StopMonitorThreads() {
    crossfadeRunning_ = false;
    amplitudeRunning_ = false;
    if (crossfadeThread_.joinable()) crossfadeThread_.join();
    if (amplitudeThread_.joinable()) amplitudeThread_.join();
}

// ─── BPM Detection Thread ─────────────────────────────────────────────────────

void LoopAudioEngine::StartBpmThread() {
    StopBpmThread();
    bpmRunning_ = true;
    // Capture a copy of the raw (pre-EQ) PCM so BPM detection works on the original signal.
    std::vector<float> pcmCopy;
    uint32_t sr = 0, ch = 0;
    {
        std::lock_guard<std::mutex> lock(stateMutex_);
        pcmCopy = rawFullPcm_;
        sr      = sampleRate_;
        ch      = channelCount_;
    }
    bpmThread_ = std::thread([this, pcm = std::move(pcmCopy), sr, ch]() {
        if (!bpmRunning_ || pcm.empty()) return;
        const int frames = static_cast<int>(pcm.size() / ch);
        BpmResult result = BpmDetector::Detect(pcm.data(), frames, ch, sr);
        if (!bpmRunning_) return;
        if (onBpmDetected) onBpmDetected(result);
    });
}

void LoopAudioEngine::StopBpmThread() {
    bpmRunning_ = false;
    if (bpmThread_.joinable()) bpmThread_.join();
}

// ─── Device Notifier ──────────────────────────────────────────────────────────

void LoopAudioEngine::InitDeviceNotifier() {
    HRESULT hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                  CLSCTX_INPROC_SERVER, __uuidof(IMMDeviceEnumerator),
                                  reinterpret_cast<void**>(&deviceEnumerator_));
    if (FAILED(hr) || !deviceEnumerator_) return;

    deviceNotifier_ = new DeviceNotifier(this);
    deviceEnumerator_->RegisterEndpointNotificationCallback(deviceNotifier_);
}

void LoopAudioEngine::TeardownDeviceNotifier() {
    if (deviceEnumerator_ && deviceNotifier_) {
        deviceEnumerator_->UnregisterEndpointNotificationCallback(deviceNotifier_);
        deviceNotifier_->Release();
        deviceNotifier_ = nullptr;
    }
    if (deviceEnumerator_) {
        deviceEnumerator_->Release();
        deviceEnumerator_ = nullptr;
    }
}

// ─── One-shot completion ──────────────────────────────────────────────────────

void LoopAudioEngine::PostPlaybackComplete() {
    // Called on an XAudio2 internal thread. Must not block or join threads.
    // Signal monitor threads to exit; they will join on the next Play()/Stop() call.
    crossfadeRunning_ = false;
    amplitudeRunning_ = false;
    SetState(EngineState::stopped);
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

void LoopAudioEngine::ApplyPanVolume() {
    ApplyPanVolumeToVoice(voiceA_);
    ApplyPanVolumeToVoice(voiceB_);
}

void LoopAudioEngine::ApplyPanVolumeToVoice(IXAudio2SourceVoice* voice) {
    if (!voice || !masterVoice_) return;

    const float angle = (pan_ + 1.0f) * 3.14159265f * 0.25f;  // [0, π/2]
    const float left  = std::cos(angle);
    const float right = std::sin(angle);

    DWORD inCh = 0, outCh = 0;
    {
        XAUDIO2_VOICE_DETAILS vd;
        voice->GetVoiceDetails(&vd);
        inCh = vd.InputChannels;
    }
    {
        XAUDIO2_VOICE_DETAILS vd;
        masterVoice_->GetVoiceDetails(&vd);
        outCh = vd.InputChannels;
    }
    if (inCh == 0 || outCh < 2) return;

    std::vector<float> matrix(inCh * outCh, 0.f);
    for (DWORD i = 0; i < inCh; ++i) {
        matrix[i * outCh + 0] = left;
        matrix[i * outCh + 1] = right;
    }
    voice->SetOutputMatrix(masterVoice_, inCh, outCh, matrix.data());
}

void LoopAudioEngine::SetState(EngineState s) {
    if (state_ == s) return;
    state_ = s;
    if (onStateChange) onStateChange(s);
}

const std::vector<float>& LoopAudioEngine::ActivePcm() const {
    return loopPcm_.empty() ? fullPcm_ : loopPcm_;
}

int LoopAudioEngine::ActiveFrames() const {
    return static_cast<int>(ActivePcm().size() / channelCount_);
}

double LoopAudioEngine::ActiveStart() const {
    return loopPcm_.empty() ? 0.0 : loopStart_;
}

// ─── Tier 3: EQ + Cutoff Filter ───────────────────────────────────────────────

void LoopAudioEngine::SetEq(float lowGainDb, float midGainDb, float highGainDb) {
    std::lock_guard<std::mutex> lock(stateMutex_);
    eqLowGainDb_  = lowGainDb;
    eqMidGainDb_  = midGainDb;
    eqHighGainDb_ = highGainDb;
    ApplyEqToBuffers(/*resubmit=*/true);
}

void LoopAudioEngine::ResetEq() {
    SetEq(0.f, 0.f, 0.f);
}

void LoopAudioEngine::SetCutoffFilter(float cutoffHz, int type, float resonance) {
    std::lock_guard<std::mutex> lock(stateMutex_);
    cutoffHz_   = cutoffHz;
    cutoffType_ = type;
    cutoffQ_    = resonance;
    ApplyEqToBuffers(/*resubmit=*/true);
}

void LoopAudioEngine::ResetCutoffFilter() {
    std::lock_guard<std::mutex> lock(stateMutex_);
    cutoffHz_ = 0.f;
    ApplyEqToBuffers(/*resubmit=*/true);
}

/// Applies current EQ + cutoff settings to rawFullPcm_ (and rawLoopPcm_),
/// updating fullPcm_ and loopPcm_. Rebuilds xfade buffers if needed.
/// If [resubmit] is true and the engine is playing, stops and resubmits.
///
/// Must be called with stateMutex_ held.
void LoopAudioEngine::ApplyEqToBuffers(bool resubmit) {
    if (rawFullPcm_.empty()) return;  // not loaded yet

    // Build filter bank from current settings.
    BiquadFilterBank bank(static_cast<int>(channelCount_));
    bank.SetLowShelf(eqLowGainDb_, static_cast<int>(sampleRate_));
    bank.SetPeaking (eqMidGainDb_, static_cast<int>(sampleRate_));
    bank.SetHighShelf(eqHighGainDb_, static_cast<int>(sampleRate_));
    if (cutoffHz_ > 0.f)
        bank.SetCutoff(cutoffHz_, cutoffType_, cutoffQ_, static_cast<int>(sampleRate_));

    // Apply to fullPcm_.
    fullPcm_ = rawFullPcm_;
    bank.Process(fullPcm_.data(), static_cast<int>(fullPcm_.size()));

    // Apply to loopPcm_ if a loop region is active.
    if (!rawLoopPcm_.empty()) {
        loopPcm_ = rawLoopPcm_;
        bank.ResetState();
        bank.Process(loopPcm_.data(), static_cast<int>(loopPcm_.size()));
    }

    // Rebuild crossfade buffers (they reference fullPcm_/loopPcm_).
    if (crossfadeDuration_ > 0.0 && !fullPcm_.empty()) {
        mainLoopPcm_.clear();
        xfadeHeadPcm_.clear();
        // RebuildXfadeBuffers() reads ActivePcm() which is now updated.
        // It does NOT take the mutex, so calling inside the lock is safe.
        RebuildXfadeBuffers();
    }

    if (!resubmit || !voiceA_) return;

    const bool wasPlaying = (state_ == EngineState::playing);
    if (wasPlaying) {
        StopMonitorThreads();
        voiceA_->Stop();
        voiceA_->FlushSourceBuffers();
        if (voiceB_) { voiceB_->Stop(); voiceB_->FlushSourceBuffers(); }
        xfadeHeadPending_ = false;

        SubmitLoopBuffer();
        voiceA_->Start();
        if (voiceB_ && (mode_ == PlaybackMode::C || mode_ == PlaybackMode::D))
            voiceB_->Start();
        StartMonitorThreads();
    }
}
