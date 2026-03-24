#pragma once
#include <string>
#include <vector>
#include <functional>
#include <mutex>
#include <thread>
#include <atomic>
#include "miniaudio.h"

class MetronomeEngine {
public:
    MetronomeEngine();
    ~MetronomeEngine();
    MetronomeEngine(const MetronomeEngine&)            = delete;
    MetronomeEngine& operator=(const MetronomeEngine&) = delete;

    std::function<void(int)>         onBeatTick;
    std::function<void(std::string)> onError;

    std::shared_ptr<std::atomic<bool>> alive_;

    void Start(double bpm, int beatsPerBar,
               const std::vector<uint8_t>& clickData,
               const std::vector<uint8_t>& accentData,
               const std::string& fileExtension);
    void Stop();
    void SetBpm(double bpm);
    void SetBeatsPerBar(int beatsPerBar);
    void SetVolume(float volume);
    void SetPan(float pan);
    void Dispose();

private:
    ma_device device_{};
    bool      deviceInited_ = false;
    bool      isRunning_    = false;

    std::vector<float> barPcm_;
    std::vector<float> clickPcm_;
    std::vector<float> accentPcm_;
    uint32_t clickSampleRate_ = 44100;
    uint32_t clickChannels_   = 1;
    uint64_t barFrames_       = 0;
    double   readPos_         = 0.0;

    double currentBpm_         = 120.0;
    int    currentBeatsPerBar_ = 4;

    std::atomic<float> volume_{1.0f};
    std::atomic<float> panLeft_{1.0f};
    std::atomic<float> panRight_{1.0f};

    std::thread       beatThread_;
    std::atomic<bool> beatRunning_{false};
    int               beatIndex_ = 0;

    mutable std::mutex mutex_;

    bool BuildBarBuffer();
    void DecodeBytes(const std::vector<uint8_t>& data, const std::string& ext,
                     std::vector<float>& out, uint32_t& sr, uint32_t& ch);
    void MixInto(std::vector<float>& dest, uint64_t destFrames,
                 const std::vector<float>& src, uint64_t srcFrames,
                 int channels, uint64_t offsetFrame);
    void StartBeatTimer();
    void StopBeatTimer();
    void RebuildAndRestart();

    static void DataCallback(ma_device*, void* out, const void*, ma_uint32 frameCount);
};
