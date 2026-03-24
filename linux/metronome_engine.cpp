#include "metronome_engine.h"
MetronomeEngine::MetronomeEngine() : alive_(std::make_shared<std::atomic<bool>>(true)) {}
MetronomeEngine::~MetronomeEngine() { Dispose(); }
void MetronomeEngine::Start(double, int, const std::vector<uint8_t>&,
    const std::vector<uint8_t>&, const std::string&) {}
void MetronomeEngine::Stop()               {}
void MetronomeEngine::SetBpm(double)        {}
void MetronomeEngine::SetBeatsPerBar(int)   {}
void MetronomeEngine::SetVolume(float)      {}
void MetronomeEngine::SetPan(float)         {}
void MetronomeEngine::Dispose()             {}
bool MetronomeEngine::BuildBarBuffer()      { return false; }
void MetronomeEngine::DecodeBytes(const std::vector<uint8_t>&, const std::string&,
    std::vector<float>&, uint32_t&, uint32_t&) {}
void MetronomeEngine::MixInto(std::vector<float>&, uint64_t,
    const std::vector<float>&, uint64_t, int, uint64_t) {}
void MetronomeEngine::StartBeatTimer()      {}
void MetronomeEngine::StopBeatTimer()       {}
void MetronomeEngine::RebuildAndRestart()   {}
void MetronomeEngine::DataCallback(ma_device* pDev, void* out, const void*, ma_uint32 fc) {
    memset(out, 0, fc * pDev->playback.channels * sizeof(float));
}
