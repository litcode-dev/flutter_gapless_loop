#pragma once
#include <string>
#include <vector>
#include <functional>
#include <mutex>
#include <thread>
#include <atomic>
#include <memory>
#include "bpm_detector.h"
#include "miniaudio.h"

enum class EngineState { idle, loading, ready, playing, paused, stopped, error };

inline const char* EngineStateStr(EngineState s) {
    switch (s) {
    case EngineState::idle:    return "idle";
    case EngineState::loading: return "loading";
    case EngineState::ready:   return "ready";
    case EngineState::playing: return "playing";
    case EngineState::paused:  return "paused";
    case EngineState::stopped: return "stopped";
    case EngineState::error:   return "error";
    }
    return "unknown";
}

class LoopAudioEngine {
public:
    LoopAudioEngine();
    ~LoopAudioEngine();
    LoopAudioEngine(const LoopAudioEngine&)            = delete;
    LoopAudioEngine& operator=(const LoopAudioEngine&) = delete;

    // Callbacks — invoked from audio/background threads; caller marshals to main.
    std::function<void(EngineState)>                   onStateChange;
    std::function<void(std::string)>                   onError;
    std::function<void(std::string)>                   onRouteChange;
    std::function<void(BpmResult)>                     onBpmDetected;
    std::function<void(float /*rms*/, float /*peak*/)> onAmplitude;

    // Lifetime sentinel — set *alive_ = false before destroying.
    std::shared_ptr<std::atomic<bool>> alive_;

    bool   LoadFile(const std::string& path);
    bool   LoadUrl(const std::string& url);
    void   Play();
    void   Pause();
    void   Resume();
    void   Stop();
    bool   SetLoopRegion(double startSecs, double endSecs);
    void   SetCrossfadeDuration(double durationSecs);
    void   SetVolume(float volume);
    void   SetPan(float pan);
    void   SetPlaybackRate(float rate);
    bool   Seek(double positionSecs);
    double GetDuration()        const;
    double GetCurrentPosition() const;
    void   Dispose();
    void   HandleReroute();   // called on main thread after device reroute

private:
    ma_device device_{};
    bool      deviceInited_ = false;

    std::vector<float> fullPcm_;
    uint32_t sampleRate_   = 44100;
    uint32_t channelCount_ = 2;
    double   fileDuration_ = 0.0;

    // Loop region (in frames; 0 / totalFrames_ = full file)
    uint64_t loopStartFrame_ = 0;
    uint64_t loopEndFrame_   = 0;
    uint64_t totalFrames_    = 0;

    // Crossfade
    double crossfadeDuration_ = 0.0;
    int    xfadeFrames_       = 0;
    std::vector<float> xfadeOut_;   // cos ramp [xfadeFrames_]
    std::vector<float> xfadeIn_;    // sin ramp [xfadeFrames_]

    // Playback position (owned by audio callback while device is running)
    double readPos_ = 0.0;

    // Config (atomics — written from main, read from callback)
    std::atomic<float>   volume_{1.0f};
    std::atomic<float>   panLeft_{1.0f};
    std::atomic<float>   panRight_{1.0f};
    std::atomic<float>   rate_{1.0f};
    std::atomic<bool>    playing_{false};

    // Amplitude gate counter
    std::atomic<uint64_t> ampFrameCounter_{0};
    static constexpr uint64_t kAmpEmitInterval = 2205;  // ~20 Hz at 44100

    EngineState        state_ = EngineState::idle;
    mutable std::mutex stateMutex_;

    bool  wasPlayingBeforeReroute_ = false;

    // BPM detection thread
    std::thread       bpmThread_;
    std::atomic<bool> bpmRunning_{false};

    void SetState(EngineState s);
    void InitDevice();
    void TeardownDevice();
    void RebuildXfadeRamps();
    void StartBpmThread();
    void StopBpmThread();

    static void DataCallback(ma_device*, void* out, const void*, ma_uint32 frameCount);
    static void NotificationCallback(const ma_device_notification*);
};
