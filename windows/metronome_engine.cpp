#include "metronome_engine.h"
#include "audio_decoder.h"
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <wrl/client.h>
#include <cmath>
#include <algorithm>
#include <sstream>

using Microsoft::WRL::ComPtr;

// ─── Constructor / Destructor ────────────────────────────────────────────────

MetronomeEngine::MetronomeEngine() {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
}

MetronomeEngine::~MetronomeEngine() {
    Dispose();
    CoUninitialize();
}

// ─── Public API ───────────────────────────────────────────────────────────────

void MetronomeEngine::Start(double bpm, int beatsPerBar,
                             const std::vector<uint8_t>& clickData,
                             const std::vector<uint8_t>& accentData,
                             const std::string& fileExtension) {
    uint32_t sr = 0, ch = 0;
    if (!DecodeBytes(clickData,  fileExtension, clickPcm_,  sr, ch) ||
        !DecodeBytes(accentData, fileExtension, accentPcm_, sr, ch)) {
        if (onError) onError("MetronomeEngine: failed to decode click/accent audio");
        return;
    }
    clickSampleRate_ = sr;
    clickChannels_   = ch;
    currentBpm_         = bpm;
    currentBeatsPerBar_ = beatsPerBar;

    if (!BuildBarBuffer()) {
        if (onError) onError("MetronomeEngine: failed to build bar buffer");
        return;
    }

    if (!InitXAudio2()) {
        if (onError) onError("MetronomeEngine: XAudio2 init failed");
        return;
    }
    SubmitBarBuffer();
    sourceVoice_->Start();
    isRunning_ = true;
    StartBeatTimer();
}

void MetronomeEngine::Stop() {
    StopBeatTimer();
    if (sourceVoice_) {
        sourceVoice_->Stop();
        sourceVoice_->FlushSourceBuffers();
    }
    isRunning_ = false;
}

void MetronomeEngine::SetBpm(double bpm) {
    if (!isRunning_) return;
    currentBpm_ = bpm;
    RebuildAndRestart();
}

void MetronomeEngine::SetBeatsPerBar(int beatsPerBar) {
    if (!isRunning_) return;
    currentBeatsPerBar_ = beatsPerBar;
    RebuildAndRestart();
}

void MetronomeEngine::SetVolume(float volume) {
    volume_ = volume;
    if (masterVoice_) masterVoice_->SetVolume(volume);
}

void MetronomeEngine::SetPan(float pan) {
    pan_ = pan;
    ApplyPanVolume();
}

void MetronomeEngine::Dispose() {
    Stop();
    TeardownXAudio2();
}

// ─── XAudio2 Graph ────────────────────────────────────────────────────────────

bool MetronomeEngine::InitXAudio2() {
    TeardownXAudio2();

    HRESULT hr = XAudio2Create(&xaudio2_, 0, XAUDIO2_DEFAULT_PROCESSOR);
    if (FAILED(hr)) return false;

    hr = xaudio2_->CreateMasteringVoice(&masterVoice_);
    if (FAILED(hr)) return false;

    masterVoice_->SetVolume(volume_);

    WAVEFORMATEX wfx = {};
    wfx.wFormatTag      = WAVE_FORMAT_IEEE_FLOAT;
    wfx.nChannels       = static_cast<WORD>(clickChannels_);
    wfx.nSamplesPerSec  = clickSampleRate_;
    wfx.wBitsPerSample  = 32;
    wfx.nBlockAlign     = wfx.nChannels * wfx.wBitsPerSample / 8;
    wfx.nAvgBytesPerSec = wfx.nSamplesPerSec * wfx.nBlockAlign;

    hr = xaudio2_->CreateSourceVoice(&sourceVoice_, &wfx,
                                      0, XAUDIO2_MAX_FREQ_RATIO);
    if (FAILED(hr)) return false;

    ApplyPanVolume();
    return true;
}

void MetronomeEngine::TeardownXAudio2() {
    if (sourceVoice_) {
        sourceVoice_->DestroyVoice();
        sourceVoice_ = nullptr;
    }
    if (masterVoice_) {
        masterVoice_->DestroyVoice();
        masterVoice_ = nullptr;
    }
    if (xaudio2_) {
        xaudio2_->Release();
        xaudio2_ = nullptr;
    }
}

// ─── Bar Buffer ───────────────────────────────────────────────────────────────

bool MetronomeEngine::BuildBarBuffer() {
    if (clickPcm_.empty() || accentPcm_.empty()) return false;

    const int beatFrames = static_cast<int>(
        clickSampleRate_ * 60.0 / currentBpm_);
    const int barFrames  = beatFrames * currentBeatsPerBar_;

    barPcm_.assign(static_cast<size_t>(barFrames) * clickChannels_, 0.f);

    MixInto(barPcm_, barFrames,
            accentPcm_, static_cast<int>(accentPcm_.size() / clickChannels_),
            static_cast<int>(clickChannels_), 0);

    for (int beat = 1; beat < currentBeatsPerBar_; ++beat) {
        MixInto(barPcm_, barFrames,
                clickPcm_, static_cast<int>(clickPcm_.size() / clickChannels_),
                static_cast<int>(clickChannels_), beat * beatFrames);
    }

    ApplyMicroFade(barPcm_, clickSampleRate_, clickChannels_);
    return true;
}

void MetronomeEngine::SubmitBarBuffer() {
    if (!sourceVoice_ || barPcm_.empty()) return;

    XAUDIO2_BUFFER buf = {};
    buf.pAudioData  = reinterpret_cast<const BYTE*>(barPcm_.data());
    buf.AudioBytes  = static_cast<UINT32>(barPcm_.size() * sizeof(float));
    buf.LoopCount   = XAUDIO2_LOOP_INFINITE;

    sourceVoice_->Stop();
    sourceVoice_->FlushSourceBuffers();
    sourceVoice_->SubmitSourceBuffer(&buf);
}

void MetronomeEngine::MixInto(std::vector<float>& dest, int destFrames,
                               const std::vector<float>& src, int srcFrames,
                               int channelCount, int offsetFrame) {
    const int remaining  = destFrames - offsetFrame;
    if (remaining <= 0) return;
    const int framesToCopy = std::min(srcFrames, remaining);

    for (int i = 0; i < framesToCopy; ++i)
        for (int ch = 0; ch < channelCount; ++ch)
            dest[static_cast<size_t>(offsetFrame + i) * channelCount + ch]
                += src[static_cast<size_t>(i) * channelCount + ch];

    // Clamp to prevent distortion.
    const size_t totalSamples = static_cast<size_t>(destFrames) * channelCount;
    for (size_t i = 0; i < totalSamples; ++i)
        dest[i] = std::max(-1.f, std::min(1.f, dest[i]));
}

void MetronomeEngine::ApplyMicroFade(std::vector<float>& pcm,
                                     uint32_t sr, uint32_t ch) {
    AudioDecoder::ApplyMicroFade(pcm, sr, ch);
}

// ─── Beat Timer ───────────────────────────────────────────────────────────────

void MetronomeEngine::StartBeatTimer() {
    StopBeatTimer();
    beatIndex_         = 0;
    beatThreadRunning_ = true;

    const double bpm        = currentBpm_;
    const int    beatsPerBar = currentBeatsPerBar_;

    beatThread_ = std::thread([this, bpm, beatsPerBar]() {
        const auto beatInterval = std::chrono::nanoseconds(
            static_cast<long long>(60'000'000'000.0 / bpm));

        auto next = std::chrono::steady_clock::now();
        while (beatThreadRunning_) {
            if (onBeatTick) onBeatTick(beatIndex_);
            beatIndex_ = (beatIndex_ + 1) % beatsPerBar;
            next += beatInterval;
            std::this_thread::sleep_until(next);
        }
    });
}

void MetronomeEngine::StopBeatTimer() {
    beatThreadRunning_ = false;
    if (beatThread_.joinable()) beatThread_.join();
    beatIndex_ = 0;
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

void MetronomeEngine::RebuildAndRestart() {
    StopBeatTimer();
    if (!BuildBarBuffer()) {
        if (onError) onError("MetronomeEngine: failed to rebuild bar buffer");
        return;
    }
    SubmitBarBuffer();
    sourceVoice_->Start();
    StartBeatTimer();
}

bool MetronomeEngine::DecodeBytes(const std::vector<uint8_t>& data,
                                   const std::string& ext,
                                   std::vector<float>& outPcm,
                                   uint32_t& outSr, uint32_t& outCh) {
    // Write bytes to a temp file.
    wchar_t tmpDir[MAX_PATH];
    GetTempPathW(MAX_PATH, tmpDir);
    const std::wstring tmpPath = std::wstring(tmpDir)
        + L"fgl_metro_" + std::to_wstring(GetTickCount64())
        + L"." + std::wstring(ext.begin(), ext.end());

    HANDLE hFile = CreateFileW(tmpPath.c_str(), GENERIC_WRITE, 0, nullptr,
                               CREATE_ALWAYS, FILE_ATTRIBUTE_TEMPORARY, nullptr);
    if (hFile == INVALID_HANDLE_VALUE) return false;

    DWORD written = 0;
    WriteFile(hFile, data.data(), static_cast<DWORD>(data.size()), &written, nullptr);
    CloseHandle(hFile);

    DecodedAudio decoded;
    const HRESULT hr = AudioDecoder::Decode(tmpPath, decoded);
    DeleteFileW(tmpPath.c_str());
    if (FAILED(hr) || decoded.pcm.empty()) return false;

    outPcm = std::move(decoded.pcm);
    outSr  = decoded.sampleRate;
    outCh  = decoded.channelCount;
    return true;
}

void MetronomeEngine::ApplyPanVolume() {
    if (!sourceVoice_ || !masterVoice_) return;
    // Equal-power stereo pan.
    const float angle = (pan_ + 1.0f) * 3.14159265f * 0.25f;  // [0, π/2]
    const float left  = std::cos(angle);
    const float right = std::sin(angle);

    DWORD inCh = 0, outCh = 0;
    DWORD mask = 0;
    masterVoice_->GetChannelMask(&mask);
    {
        XAUDIO2_VOICE_DETAILS vd;
        sourceVoice_->GetVoiceDetails(&vd);
        inCh = vd.InputChannels;
    }
    {
        XAUDIO2_VOICE_DETAILS vd;
        masterVoice_->GetVoiceDetails(&vd);
        outCh = vd.InputChannels;
    }
    if (inCh == 0 || outCh < 2) return;

    // Build output matrix: each input channel fans out to L/R output channels.
    std::vector<float> matrix(inCh * outCh, 0.f);
    for (DWORD i = 0; i < inCh; ++i) {
        matrix[i * outCh + 0] = left;
        if (outCh >= 2) matrix[i * outCh + 1] = right;
    }
    sourceVoice_->SetOutputMatrix(masterVoice_, inCh, outCh, matrix.data());
}
