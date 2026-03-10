#pragma once
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <string>
#include <vector>
#include <cstdint>

/// PCM audio decoded from a file. Samples are interleaved 32-bit float, [-1.0, 1.0].
struct DecodedAudio {
    std::vector<float> pcm;          ///< Interleaved float samples.
    uint32_t sampleRate   = 0;
    uint32_t channelCount = 0;
    uint64_t totalFrames  = 0;
};

/// Decodes audio files to float PCM using Windows MediaFoundation.
/// Supports MP3, AAC, FLAC, WAV, OGG/Vorbis, and any format with an installed MF codec.
class AudioDecoder {
public:
    /// One-time initialisation. Call before any Decode(). Returns MFStartup HRESULT.
    static HRESULT Startup();

    /// One-time shutdown. Call when the plugin unloads.
    static void    Shutdown();

    /// Decode an audio file at |path| into |out|.
    static HRESULT Decode(const std::wstring& path, DecodedAudio& out);

    /// Download |url| (http/https) to a temp file, decode, and clean up.
    /// Blocking — must be called from a background thread.
    static HRESULT DecodeUrl(const std::wstring& url, DecodedAudio& out);

    /// Apply 5 ms linear micro-fades in-place at both ends of |pcm|.
    /// Prevents clicks at the loop boundary. Safe to call off the audio thread.
    static void ApplyMicroFade(std::vector<float>& pcm,
                               uint32_t sampleRate,
                               uint32_t channelCount);
};
