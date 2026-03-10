#pragma once
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <xaudio2.h>
#include <string>
#include <vector>
#include <functional>
#include <mutex>
#include <thread>
#include <atomic>

/// Sample-accurate metronome backed by XAudio2.
///
/// Generates a single-bar PCM buffer (accent at frame 0, click at beats 1…N-1)
/// and loops it indefinitely via XAUDIO2_LOOP_INFINITE.
/// Beat-tick events (UI hint, ±5 ms jitter) are emitted via a background thread timer.
class MetronomeEngine {
public:
    MetronomeEngine();
    ~MetronomeEngine();

    // Non-copyable.
    MetronomeEngine(const MetronomeEngine&) = delete;
    MetronomeEngine& operator=(const MetronomeEngine&) = delete;

    // ── Callbacks (called on the beat-timer thread; caller must marshal to main) ──

    std::function<void(int)>         onBeatTick;   ///< Beat index: 0=accent, 1…N-1=click.
    std::function<void(std::string)> onError;

    // ── Public API ────────────────────────────────────────────────────────────

    /// Decode click/accent bytes, build bar buffer, start looping.
    void Start(double bpm, int beatsPerBar,
               const std::vector<uint8_t>& clickData,
               const std::vector<uint8_t>& accentData,
               const std::string& fileExtension);

    void Stop();

    /// Rebuild bar buffer at new tempo. No-op if not started.
    void SetBpm(double bpm);

    /// Rebuild bar buffer with new time signature. No-op if not started.
    void SetBeatsPerBar(int beatsPerBar);

    void SetVolume(float volume);
    void SetPan(float pan);
    void Dispose();

private:
    // ── XAudio2 graph ─────────────────────────────────────────────────────────
    IXAudio2*              xaudio2_       = nullptr;
    IXAudio2MasteringVoice* masterVoice_  = nullptr;
    IXAudio2SourceVoice*   sourceVoice_   = nullptr;

    // ── PCM buffers ───────────────────────────────────────────────────────────
    std::vector<float> clickPcm_;
    std::vector<float> accentPcm_;
    uint32_t           clickSampleRate_   = 44100;
    uint32_t           clickChannels_     = 1;
    std::vector<float> barPcm_;

    // ── State ─────────────────────────────────────────────────────────────────
    double currentBpm_        = 120.0;
    int    currentBeatsPerBar_= 4;
    bool   isRunning_         = false;
    float  volume_            = 1.0f;
    float  pan_               = 0.0f;

    // ── Beat timer thread ─────────────────────────────────────────────────────
    std::thread       beatThread_;
    std::atomic<bool> beatThreadRunning_{false};
    int               beatIndex_ = 0;

    // ── Helpers ───────────────────────────────────────────────────────────────
    bool           InitXAudio2();
    void           TeardownXAudio2();
    bool           BuildBarBuffer();
    void           SubmitBarBuffer();
    bool           DecodeBytes(const std::vector<uint8_t>& data,
                               const std::string& ext,
                               std::vector<float>& outPcm,
                               uint32_t& outSr, uint32_t& outCh);
    void           ApplyMicroFade(std::vector<float>& pcm,
                                  uint32_t sr, uint32_t ch);
    void           MixInto(std::vector<float>& dest, int destFrames,
                            const std::vector<float>& src, int srcFrames,
                            int channelCount, int offsetFrame);
    void           StartBeatTimer();
    void           StopBeatTimer();
    void           RebuildAndRestart();
    void           ApplyPanVolume();
};
