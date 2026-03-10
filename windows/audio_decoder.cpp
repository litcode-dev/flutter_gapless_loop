#include "audio_decoder.h"
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>
#include <wrl/client.h>
#include <urlmon.h>
#include <cstdlib>
#include <algorithm>

using Microsoft::WRL::ComPtr;

// ─── Startup / Shutdown ───────────────────────────────────────────────────────

HRESULT AudioDecoder::Startup() {
    return MFStartup(MF_VERSION, MFSTARTUP_NOSOCKET);
}

void AudioDecoder::Shutdown() {
    MFShutdown();
}

// ─── Decode ───────────────────────────────────────────────────────────────────

HRESULT AudioDecoder::Decode(const std::wstring& path, DecodedAudio& out) {
    ComPtr<IMFSourceReader> reader;
    HRESULT hr = MFCreateSourceReaderFromURL(path.c_str(), nullptr, &reader);
    if (FAILED(hr)) return hr;

    // Enable only the first audio stream.
    reader->SetStreamSelection(MF_SOURCE_READER_ALL_STREAMS, FALSE);
    reader->SetStreamSelection(MF_SOURCE_READER_FIRST_AUDIO_STREAM, TRUE);

    // Request decoded 32-bit float PCM output.
    ComPtr<IMFMediaType> outType;
    hr = MFCreateMediaType(&outType);
    if (FAILED(hr)) return hr;
    outType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
    outType->SetGUID(MF_MT_SUBTYPE,    MFAudioFormat_Float);
    hr = reader->SetCurrentMediaType(MF_SOURCE_READER_FIRST_AUDIO_STREAM,
                                     nullptr, outType.Get());
    if (FAILED(hr)) return hr;

    // Read the negotiated output format.
    ComPtr<IMFMediaType> actual;
    reader->GetCurrentMediaType(MF_SOURCE_READER_FIRST_AUDIO_STREAM, &actual);

    UINT32 sr = 0, ch = 0;
    actual->GetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, &sr);
    actual->GetUINT32(MF_MT_AUDIO_NUM_CHANNELS,        &ch);

    std::vector<float> samples;
    samples.reserve(static_cast<size_t>(sr) * ch * 30);  // 30-second initial reservation

    for (;;) {
        DWORD flags = 0;
        ComPtr<IMFSample> sample;
        hr = reader->ReadSample(MF_SOURCE_READER_FIRST_AUDIO_STREAM,
                                0, nullptr, &flags, nullptr, &sample);
        if (FAILED(hr)) break;
        if (flags & MF_SOURCE_READERF_ENDOFSTREAM) break;
        if (!sample) continue;

        ComPtr<IMFMediaBuffer> buf;
        if (FAILED(sample->ConvertToContiguousBuffer(&buf))) continue;

        BYTE* data   = nullptr;
        DWORD used   = 0;
        if (FAILED(buf->Lock(&data, nullptr, &used))) continue;

        const DWORD  count = used / sizeof(float);
        const float* src   = reinterpret_cast<const float*>(data);
        samples.insert(samples.end(), src, src + count);

        buf->Unlock();
    }

    out.sampleRate   = sr;
    out.channelCount = ch;
    out.totalFrames  = (ch > 0) ? samples.size() / ch : 0;
    out.pcm          = std::move(samples);
    return S_OK;
}

// ─── DecodeUrl ────────────────────────────────────────────────────────────────

HRESULT AudioDecoder::DecodeUrl(const std::wstring& url, DecodedAudio& out) {
    // Extract extension for the temp file.
    std::wstring ext = L"wav";
    auto dot = url.rfind(L'.');
    if (dot != std::wstring::npos) {
        auto slash = url.rfind(L'/');
        if (slash == std::wstring::npos || dot > slash) {
            ext = url.substr(dot + 1);
            auto q = ext.find(L'?');
            if (q != std::wstring::npos) ext = ext.substr(0, q);
        }
    }

    wchar_t tmpDir[MAX_PATH];
    GetTempPathW(MAX_PATH, tmpDir);

    // Unique temp file path.
    const std::wstring tmpPath = std::wstring(tmpDir)
        + L"fgl_" + std::to_wstring(GetTickCount64()) + L"." + ext;

    // Blocking download — caller MUST run this on a background thread.
    HRESULT hr = URLDownloadToFileW(nullptr, url.c_str(), tmpPath.c_str(),
                                    0, nullptr);
    if (FAILED(hr)) return hr;

    hr = Decode(tmpPath, out);
    DeleteFileW(tmpPath.c_str());
    return hr;
}

// ─── ApplyMicroFade ───────────────────────────────────────────────────────────

void AudioDecoder::ApplyMicroFade(std::vector<float>& pcm,
                                  uint32_t sampleRate,
                                  uint32_t channelCount) {
    if (channelCount == 0 || pcm.empty()) return;

    const int fadeFrames  = std::max(1, static_cast<int>(sampleRate * 0.005));
    const int totalFrames = static_cast<int>(pcm.size() / channelCount);

    for (int i = 0; i < fadeFrames && i < totalFrames; ++i) {
        const float gain = static_cast<float>(i) / static_cast<float>(fadeFrames);
        for (uint32_t ch = 0; ch < channelCount; ++ch) {
            pcm[static_cast<size_t>(i) * channelCount + ch] *= gain;
            const int endFrame = totalFrames - 1 - i;
            if (endFrame > i)
                pcm[static_cast<size_t>(endFrame) * channelCount + ch] *= gain;
        }
    }
}
