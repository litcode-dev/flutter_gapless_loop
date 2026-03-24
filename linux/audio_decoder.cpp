#include "audio_decoder.h"
#include "miniaudio.h"
#include <curl/curl.h>
#include <unistd.h>
#include <random>
#include <sstream>
#include <iomanip>
#include <cstdio>
#include <cstring>

// ── Helpers ───────────────────────────────────────────────────────────────────

static std::string RandomHex(int bytes) {
    std::random_device rd;
    std::mt19937 gen(rd());
    std::uniform_int_distribution<uint32_t> dist(0, 0xFFFFFFFF);
    std::ostringstream oss;
    for (int i = 0; i < (bytes + 3) / 4; ++i)
        oss << std::hex << std::setw(8) << std::setfill('0') << dist(gen);
    return oss.str().substr(0, bytes * 2);
}

// ── Decode ────────────────────────────────────────────────────────────────────

bool AudioDecoder::Decode(const std::string& path, DecodedAudio& out) {
    ma_decoder_config cfg = ma_decoder_config_init(ma_format_f32, 0, 0);
    ma_decoder decoder;

    if (ma_decoder_init_file(path.c_str(), &cfg, &decoder) != MA_SUCCESS)
        return false;

    out.sampleRate   = decoder.outputSampleRate;
    out.channelCount = decoder.outputChannels;

    // Guard: unsupported format can leave these as 0
    if (out.channelCount == 0 || out.sampleRate == 0) {
        ma_decoder_uninit(&decoder);
        return false;
    }

    ma_uint64 totalFrames = 0;
    if (ma_decoder_get_length_in_pcm_frames(&decoder, &totalFrames) == MA_SUCCESS
        && totalFrames > 0) {
        // Pre-allocate — fast path for formats with known length (WAV, FLAC)
        out.pcm.resize(totalFrames * out.channelCount);
        ma_uint64 read = 0;
        ma_decoder_read_pcm_frames(&decoder, out.pcm.data(), totalFrames, &read);
        out.pcm.resize(read * out.channelCount);
        out.totalFrames = read;
    } else {
        // Chunked-read fallback — VBR MP3, OGG (length unknown before full decode)
        constexpr ma_uint64 kChunk = 65536;
        std::vector<float> chunk(kChunk * out.channelCount);
        ma_uint64 read;
        do {
            if (ma_decoder_read_pcm_frames(&decoder, chunk.data(), kChunk, &read) != MA_SUCCESS)
                break;
            out.pcm.insert(out.pcm.end(), chunk.data(),
                           chunk.data() + read * out.channelCount);
            out.totalFrames += read;
        } while (read == kChunk);
    }

    ma_decoder_uninit(&decoder);

    if (out.totalFrames == 0) return false;

    ApplyMicroFade(out.pcm, out.sampleRate, out.channelCount);
    return true;
}

// ── URL download ──────────────────────────────────────────────────────────────

static size_t CurlWriteFile(void* ptr, size_t size, size_t nmemb, void* stream) {
    return fwrite(ptr, size, nmemb, static_cast<FILE*>(stream));
}

bool AudioDecoder::DecodeUrl(const std::string& url, DecodedAudio& out) {
    std::string tmpPath = "/tmp/fgl_" + RandomHex(8) + ".tmp";

    bool ok = false;
    FILE* fp = fopen(tmpPath.c_str(), "wb");
    if (fp) {
        CURL* curl = curl_easy_init();
        if (curl) {
            curl_easy_setopt(curl, CURLOPT_URL,           url.c_str());
            curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, CurlWriteFile);
            curl_easy_setopt(curl, CURLOPT_WRITEDATA,     fp);
            curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
            curl_easy_setopt(curl, CURLOPT_TIMEOUT,       60L);
            CURLcode res = curl_easy_perform(curl);
            long httpCode = 0;
            curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &httpCode);
            curl_easy_cleanup(curl);
            ok = (res == CURLE_OK && httpCode >= 200 && httpCode < 300);
        }
        fclose(fp);
    }

    if (ok) ok = Decode(tmpPath, out);
    unlink(tmpPath.c_str());
    return ok;
}

// ── Micro-fade ────────────────────────────────────────────────────────────────

void AudioDecoder::ApplyMicroFade(std::vector<float>& pcm,
                                   uint32_t sampleRate, uint32_t channelCount) {
    if (pcm.empty() || channelCount == 0) return;
    const uint64_t totalFrames = pcm.size() / channelCount;
    // 5 ms ramp, capped at 10% of total length
    const uint64_t rampFrames = std::min<uint64_t>(
        static_cast<uint64_t>(sampleRate * 0.005),
        totalFrames / 10);
    if (rampFrames == 0) return;

    for (uint64_t i = 0; i < rampFrames; ++i) {
        const float gain = static_cast<float>(i) / static_cast<float>(rampFrames);
        for (uint32_t ch = 0; ch < channelCount; ++ch) {
            // Fade-in at start
            pcm[i * channelCount + ch] *= gain;
            // Fade-out at end
            const uint64_t endIdx = (totalFrames - 1 - i) * channelCount + ch;
            pcm[endIdx] *= gain;
        }
    }
}
