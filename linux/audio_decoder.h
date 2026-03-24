#pragma once
#include <string>
#include <vector>
#include <cstdint>

struct DecodedAudio {
    std::vector<float> pcm;
    uint32_t sampleRate   = 0;
    uint32_t channelCount = 0;
    uint64_t totalFrames  = 0;
};

class AudioDecoder {
public:
    static bool Decode(const std::string& path, DecodedAudio& out);
    static bool DecodeUrl(const std::string& url, DecodedAudio& out);
    static void ApplyMicroFade(std::vector<float>& pcm,
                               uint32_t sampleRate, uint32_t channelCount);
};
