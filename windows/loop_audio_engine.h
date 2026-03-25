#pragma once
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <xaudio2.h>
#include <mmdeviceapi.h>
#include <string>
#include <vector>
#include <functional>
#include <mutex>
#include <thread>
#include <atomic>
#include "bpm_detector.h"
#include "biquad_filter.h"

// ─── EngineState ──────────────────────────────────────────────────────────────

enum class EngineState {
    idle,     ///< No file loaded.
    loading,  ///< Decoding audio file.
    ready,    ///< File loaded, ready to play.
    playing,  ///< Actively playing.
    paused,   ///< Paused at current position.
    stopped,  ///< Stopped (position reset).
    error     ///< Unrecoverable error.
};

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

// ─── LoopAudioEngine ──────────────────────────────────────────────────────────

/// XAudio2-backed gapless loop player.
///
/// ## Playback Modes
/// - A: Full file, no crossfade   → voiceA with XAUDIO2_LOOP_INFINITE
/// - B: Loop region, no crossfade → voiceA with XAUDIO2_LOOP_INFINITE on loopPcm_
/// - C: Full file + crossfade     → voiceA loops mainLoopPcm_ (tail faded); voiceB plays
///                                   xfadeHeadPcm_ at each loop boundary
/// - D: Loop region + crossfade
///
/// Thread safety: all public methods are individually mutex-protected and safe to call
/// from any thread, but should not be called concurrently (Flutter method channel
/// delivers calls serially on its own platform thread).
class LoopAudioEngine {
public:
    LoopAudioEngine();
    ~LoopAudioEngine();

    LoopAudioEngine(const LoopAudioEngine&)            = delete;
    LoopAudioEngine& operator=(const LoopAudioEngine&) = delete;

    // ── Callbacks ─────────────────────────────────────────────────────────────
    // Invoked from background threads. Caller is responsible for marshalling to
    // the main/UI thread before touching Flutter channels.

    std::function<void(EngineState)>                   onStateChange;
    std::function<void(std::string)>                   onError;
    std::function<void(std::string)>                   onRouteChange;
    std::function<void(BpmResult)>                     onBpmDetected;
    std::function<void(float /*rms*/, float /*peak*/)> onAmplitude;

    // ── Public API ────────────────────────────────────────────────────────────

    bool   LoadFile(const std::wstring& path);
    bool   LoadUrl(const std::wstring& url);
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

    // ── Tier 3: EQ + Cutoff Filter ────────────────────────────────────────────
    void   SetEq(float lowGainDb, float midGainDb, float highGainDb);
    void   ResetEq();
    void   SetCutoffFilter(float cutoffHz, int type, float resonance);
    void   ResetCutoffFilter();

    // Called from DeviceNotifier (COM thread) when the default audio device changes.
    void   OnDeviceChanged();

private:
    // ── XAudio2 graph ─────────────────────────────────────────────────────────
    IXAudio2*               xaudio2_     = nullptr;
    IXAudio2MasteringVoice* masterVoice_ = nullptr;
    IXAudio2SourceVoice*    voiceA_      = nullptr;   // primary loop voice
    IXAudio2SourceVoice*    voiceB_      = nullptr;   // crossfade overlay (lazy)

    // ── PCM buffers ───────────────────────────────────────────────────────────
    std::vector<float> fullPcm_;       ///< Whole file, micro-fade applied.
    std::vector<float> loopPcm_;       ///< Sub-region. Empty → use fullPcm_ (modes A/C).
    std::vector<float> mainLoopPcm_;   ///< Active PCM with tail faded out (modes C/D).
    std::vector<float> xfadeHeadPcm_;  ///< First N frames with fadeIn (submitted to voiceB).
    int                xfadeFrames_ = 0;

    uint32_t sampleRate_   = 44100;
    uint32_t channelCount_ = 2;
    double   fileDuration_ = 0.0;
    double   loopStart_    = 0.0;
    double   loopEnd_      = 0.0;

    // ── Configuration ─────────────────────────────────────────────────────────
    double crossfadeDuration_ = 0.0;
    float  volume_            = 1.0f;
    float  pan_               = 0.0f;
    float  playbackRate_      = 1.0f;

    // ── EQ / Cutoff state ─────────────────────────────────────────────────────
    // Pending settings applied via ApplyEqToBuffers() whenever the PCM changes.
    float eqLowGainDb_   = 0.f;
    float eqMidGainDb_   = 0.f;
    float eqHighGainDb_  = 0.f;
    float cutoffHz_      = 0.f;  // 0 = bypass
    int   cutoffType_    = 0;    // 0 = low-pass, 1 = high-pass
    float cutoffQ_       = 0.707f;

    // Raw PCM buffers (decoded, micro-faded, NOT EQ'd).
    // EQ is applied to these to produce fullPcm_/loopPcm_ for submission to XAudio2.
    std::vector<float> rawFullPcm_;
    std::vector<float> rawLoopPcm_;

    // ── State ─────────────────────────────────────────────────────────────────
    EngineState      state_ = EngineState::idle;
    mutable std::mutex stateMutex_;

    enum class PlaybackMode { A, B, C, D };
    PlaybackMode mode_ = PlaybackMode::A;

    // ── Monitor threads ───────────────────────────────────────────────────────
    std::thread        crossfadeThread_;
    std::atomic<bool>  crossfadeRunning_{false};
    std::atomic<bool>  xfadeHeadPending_{false};  ///< true while voiceB is playing.

    std::thread        amplitudeThread_;
    std::atomic<bool>  amplitudeRunning_{false};

    std::thread        bpmThread_;
    std::atomic<bool>  bpmRunning_{false};

    // ── XAudio2 voice callback for crossfade voiceB ───────────────────────────
    // Type-erased here; concrete type (XfadeVoiceCallback) lives in the .cpp.
    IXAudio2VoiceCallback* xfadeCallback_ = nullptr;

    // ── Device change notifications ───────────────────────────────────────────
    IMMDeviceEnumerator* deviceEnumerator_ = nullptr;
    class DeviceNotifier;
    DeviceNotifier* deviceNotifier_ = nullptr;

    // ── Helpers ───────────────────────────────────────────────────────────────
    bool  InitXAudio2();
    void  TeardownXAudio2();
    void  SubmitLoopBuffer();       ///< Submits active PCM to voiceA with LOOP_INFINITE.
    void  RebuildXfadeBuffers();    ///< Precomputes mainLoopPcm_ + xfadeHeadPcm_.
    void  SetState(EngineState s);
    void  ApplyPanVolume();
    void  ApplyPanVolumeToVoice(IXAudio2SourceVoice* voice);
    void  StartMonitorThreads();
    void  StopMonitorThreads();
    void  StartBpmThread();
    void  StopBpmThread();
    void  InitDeviceNotifier();
    void  TeardownDeviceNotifier();
    /// Applies current EQ + cutoff to rawFullPcm_ (and rawLoopPcm_ if set),
    /// updates fullPcm_ / loopPcm_, then resubmits to XAudio2 if playing.
    void  ApplyEqToBuffers(bool resubmit);

    /// Returns loopPcm_ if non-empty, otherwise fullPcm_.
    const std::vector<float>& ActivePcm() const;
    int    ActiveFrames() const;
    double ActiveStart()  const;
};
