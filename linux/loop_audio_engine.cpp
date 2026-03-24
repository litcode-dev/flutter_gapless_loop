#include "loop_audio_engine.h"
LoopAudioEngine::LoopAudioEngine()  : alive_(std::make_shared<std::atomic<bool>>(true)) {}
LoopAudioEngine::~LoopAudioEngine() { Dispose(); }
bool   LoopAudioEngine::LoadFile(const std::string&)     { return false; }
bool   LoopAudioEngine::LoadUrl(const std::string&)      { return false; }
void   LoopAudioEngine::Play()    {}
void   LoopAudioEngine::Pause()   {}
void   LoopAudioEngine::Resume()  {}
void   LoopAudioEngine::Stop()    {}
bool   LoopAudioEngine::SetLoopRegion(double, double)    { return false; }
void   LoopAudioEngine::SetCrossfadeDuration(double)     {}
void   LoopAudioEngine::SetVolume(float)                 {}
void   LoopAudioEngine::SetPan(float)                    {}
void   LoopAudioEngine::SetPlaybackRate(float)           {}
bool   LoopAudioEngine::Seek(double)                     { return false; }
double LoopAudioEngine::GetDuration()        const       { return 0.0; }
double LoopAudioEngine::GetCurrentPosition() const       { return 0.0; }
void   LoopAudioEngine::Dispose()                        {}
void   LoopAudioEngine::HandleReroute()                  {}
void   LoopAudioEngine::SetState(EngineState)            {}
void   LoopAudioEngine::InitDevice()                     {}
void   LoopAudioEngine::TeardownDevice()                 {}
void   LoopAudioEngine::RebuildXfadeRamps()              {}
void   LoopAudioEngine::StartBpmThread()                 {}
void   LoopAudioEngine::StopBpmThread()                  {}
// Use pDev->playback.channels — never hardcode channel count.
void   LoopAudioEngine::DataCallback(ma_device* pDev, void* out, const void*, ma_uint32 fc) {
    memset(out, 0, fc * pDev->playback.channels * sizeof(float));
}
void LoopAudioEngine::NotificationCallback(const ma_device_notification*) {}
