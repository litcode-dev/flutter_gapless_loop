# Linux Platform Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Linux as a fully-supported platform with feature parity to Windows (all 4 loop modes, BPM detection, crossfade, metronome, amplitude metering, URL loading).

**Architecture:** One `ma_device` per `LoopAudioEngine` instance uses miniaudio's pull/callback model; all loop, crossfade, and amplitude logic lives inside `DataCallback`. A separate `ma_device` powers `MetronomeEngine`. `g_idle_add` marshals background-thread results to Flutter's GLib main loop. GObject thin-wrapper delegates to a C++ `PluginHandler`.

**Tech Stack:** miniaudio v0.11.21 (vendored), libcurl (pkg-config), GLib/GObject (Flutter Linux embedding), C++17, CMake 3.14+.

---

## File Map

| Path | Action | Purpose |
|------|--------|---------|
| `linux/CMakeLists.txt` | Create | Build system |
| `linux/third_party/miniaudio.h` | Create | Vendored audio library |
| `linux/miniaudio_impl.cpp` | Create | Single TU that defines MINIAUDIO_IMPLEMENTATION |
| `linux/include/flutter_gapless_loop/flutter_gapless_loop_plugin.h` | Create | GObject C registration header |
| `linux/flutter_gapless_loop_plugin.cpp` | Create | Plugin bridge: GObject wrapper + C++ PluginHandler |
| `linux/audio_decoder.h` | Create | DecodedAudio struct + static decode API |
| `linux/audio_decoder.cpp` | Create | ma_decoder decode + libcurl URL download + micro-fade |
| `linux/loop_audio_engine.h` | Create | Public engine API (mirrors windows/) |
| `linux/loop_audio_engine.cpp` | Create | miniaudio playback, all 4 modes |
| `linux/bpm_detector.h` | Create | Copied verbatim from windows/ |
| `linux/bpm_detector.cpp` | Create | Copied verbatim from windows/ |
| `linux/crossfade_engine.h` | Create | Copied verbatim from windows/ (header-only) |
| `linux/metronome_engine.h` | Create | Metronome API |
| `linux/metronome_engine.cpp` | Create | ma_device metronome + beat timer |
| `pubspec.yaml` | Modify | Add linux platform, bump to 0.0.9 |
| `README.md` | Modify | Add Linux row to platform table |
| `CHANGELOG.md` | Modify | Add 0.0.9 entry |

**Reference:** Spec at `docs/superpowers/specs/2026-03-24-linux-platform-design.md`. Windows implementation at `windows/` is the primary reference for all logic.

---

## Task 1: Scaffold — Directory Structure, Build System, Stub Files

**Files:**
- Create: `linux/` (all files below)
- Modify: `pubspec.yaml`

- [ ] **Step 1: Download miniaudio v0.11.21**

```bash
mkdir -p linux/third_party
curl -L "https://raw.githubusercontent.com/mackron/miniaudio/0.11.21/miniaudio.h" \
     -o linux/third_party/miniaudio.h
```

Verify: `wc -l linux/third_party/miniaudio.h` should print ~100000+.

- [ ] **Step 2: Create `linux/miniaudio_impl.cpp`**

Exactly one TU defines `MINIAUDIO_IMPLEMENTATION`. All other TUs include `miniaudio.h` without it.

```cpp
// linux/miniaudio_impl.cpp
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"
```

- [ ] **Step 3: Copy verbatim files from `windows/`**

```bash
cp windows/bpm_detector.h   linux/bpm_detector.h
cp windows/bpm_detector.cpp linux/bpm_detector.cpp
cp windows/crossfade_engine.h linux/crossfade_engine.h
```

Edit `linux/bpm_detector.h` and `linux/bpm_detector.cpp` to remove the `#define WIN32_LEAN_AND_MEAN` and `#include <windows.h>` lines (they are not needed on Linux — the algorithm is pure C++).

- [ ] **Step 4: Create stub source files**

Create each file with the minimal content needed to compile (empty implementations). We'll fill them in subsequent tasks.

`linux/audio_decoder.h`:
```cpp
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
```

`linux/audio_decoder.cpp`:
```cpp
#include "audio_decoder.h"
bool AudioDecoder::Decode(const std::string&, DecodedAudio&) { return false; }
bool AudioDecoder::DecodeUrl(const std::string&, DecodedAudio&) { return false; }
void AudioDecoder::ApplyMicroFade(std::vector<float>&, uint32_t, uint32_t) {}
```

`linux/loop_audio_engine.h` — copy structure from `windows/loop_audio_engine.h`, replacing Windows-specific types:
```cpp
#pragma once
#include <string>
#include <vector>
#include <functional>
#include <mutex>
#include <thread>
#include <atomic>
#include <memory>
#include "bpm_detector.h"
#include "miniaudio.h"

enum class EngineState { idle, loading, ready, playing, paused, stopped, error };

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

class LoopAudioEngine {
public:
    LoopAudioEngine();
    ~LoopAudioEngine();
    LoopAudioEngine(const LoopAudioEngine&)            = delete;
    LoopAudioEngine& operator=(const LoopAudioEngine&) = delete;

    // Callbacks — invoked from audio/background threads; caller marshals to main.
    std::function<void(EngineState)>                   onStateChange;
    std::function<void(std::string)>                   onError;
    std::function<void(std::string)>                   onRouteChange;
    std::function<void(BpmResult)>                     onBpmDetected;
    std::function<void(float /*rms*/, float /*peak*/)> onAmplitude;

    // Lifetime sentinel — set *alive_ = false before destroying.
    std::shared_ptr<std::atomic<bool>> alive_;

    bool   LoadFile(const std::string& path);
    bool   LoadUrl(const std::string& url);
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
    void   HandleReroute();   // called on main thread after device reroute

private:
    ma_device device_{};
    bool      deviceInited_ = false;

    std::vector<float> fullPcm_;
    uint32_t sampleRate_   = 44100;
    uint32_t channelCount_ = 2;
    double   fileDuration_ = 0.0;

    // Loop region (in frames; 0 / totalFrames_ = full file)
    uint64_t loopStartFrame_ = 0;
    uint64_t loopEndFrame_   = 0;
    uint64_t totalFrames_    = 0;

    // Crossfade
    double crossfadeDuration_ = 0.0;
    int    xfadeFrames_       = 0;
    std::vector<float> xfadeOut_;   // cos ramp [xfadeFrames_]
    std::vector<float> xfadeIn_;    // sin ramp [xfadeFrames_]

    // Playback position (owned by audio callback while device is running)
    double readPos_ = 0.0;

    // Config (atomics — written from main, read from callback)
    std::atomic<float>   volume_{1.0f};
    std::atomic<float>   panLeft_{1.0f};
    std::atomic<float>   panRight_{1.0f};
    std::atomic<float>   rate_{1.0f};
    std::atomic<bool>    playing_{false};

    // Amplitude gate counter
    std::atomic<uint64_t> ampFrameCounter_{0};
    static constexpr uint64_t kAmpEmitInterval = 2205;  // ~20 Hz at 44100

    EngineState        state_ = EngineState::idle;
    mutable std::mutex stateMutex_;

    bool  wasPlayingBeforeReroute_ = false;

    // BPM detection thread
    std::thread       bpmThread_;
    std::atomic<bool> bpmRunning_{false};

    void SetState(EngineState s);
    void InitDevice();
    void TeardownDevice();
    void RebuildXfadeRamps();
    void StartBpmThread();
    void StopBpmThread();

    static void DataCallback(ma_device*, void* out, const void*, ma_uint32 frameCount);
    static void NotificationCallback(const ma_device_notification*);
};
```

`linux/loop_audio_engine.cpp`:
```cpp
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
```

`linux/metronome_engine.h`:
```cpp
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
```

`linux/metronome_engine.cpp`:
```cpp
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
```

`linux/include/flutter_gapless_loop/flutter_gapless_loop_plugin.h`:
```cpp
#pragma once
#include <flutter_linux/flutter_linux.h>

G_BEGIN_DECLS

#ifdef FLUTTER_PLUGIN_IMPL
#define FLUTTER_PLUGIN_EXPORT __attribute__((visibility("default")))
#else
#define FLUTTER_PLUGIN_EXPORT
#endif

typedef struct _FlutterGaplessLoopPlugin      FlutterGaplessLoopPlugin;
typedef struct _FlutterGaplessLoopPluginClass FlutterGaplessLoopPluginClass;

FLUTTER_PLUGIN_EXPORT GType flutter_gapless_loop_plugin_get_type();

FLUTTER_PLUGIN_EXPORT void flutter_gapless_loop_plugin_register_with_registrar(
    FlPluginRegistrar* registrar);

G_END_DECLS
```

`linux/flutter_gapless_loop_plugin.cpp` (stub):
```cpp
#include "include/flutter_gapless_loop/flutter_gapless_loop_plugin.h"
#include <flutter_linux/flutter_linux.h>

struct _FlutterGaplessLoopPlugin { GObject parent_instance; };
G_DEFINE_TYPE(FlutterGaplessLoopPlugin, flutter_gapless_loop_plugin, G_TYPE_OBJECT)

static void flutter_gapless_loop_plugin_class_init(FlutterGaplessLoopPluginClass*) {}
static void flutter_gapless_loop_plugin_init(FlutterGaplessLoopPlugin*)             {}

void flutter_gapless_loop_plugin_register_with_registrar(FlPluginRegistrar*) {}
```

- [ ] **Step 5: Create `linux/CMakeLists.txt`**

```cmake
cmake_minimum_required(VERSION 3.14)
project(flutter_gapless_loop_plugin)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(PkgConfig REQUIRED)
pkg_check_modules(CURL REQUIRED libcurl)

set(PLUGIN_NAME flutter_gapless_loop_plugin)

add_library(${PLUGIN_NAME} SHARED
  flutter_gapless_loop_plugin.cpp
  loop_audio_engine.cpp
  audio_decoder.cpp
  bpm_detector.cpp
  metronome_engine.cpp
  miniaudio_impl.cpp
)

apply_standard_settings(${PLUGIN_NAME})

target_include_directories(${PLUGIN_NAME} PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/third_party"
  ${CURL_INCLUDE_DIRS}
)

target_link_libraries(${PLUGIN_NAME} PUBLIC
  flutter_linux
  PkgConfig::CURL
  dl
  pthread
  m
)

target_compile_definitions(${PLUGIN_NAME} PRIVATE
  FLUTTER_PLUGIN_IMPL
)
```

- [ ] **Step 6: Add linux platform to `pubspec.yaml`**

In `pubspec.yaml`, inside `flutter.plugin.platforms`, add:
```yaml
      linux:
        pluginClass: FlutterGaplessLoopPlugin
```

Do NOT change the version yet (that happens in Task 7).

- [ ] **Step 7: Verify scaffold compiles**

```bash
cd example && flutter build linux --debug 2>&1 | tail -20
```

Expected: build succeeds (may have warnings, no errors). The app will open but audio will be silent — that's correct for stubs.

- [ ] **Step 8: Commit**

```bash
git add linux/ pubspec.yaml
git commit -m "feat(linux): scaffold — CMakeLists, headers, stubs, pubspec registration"
```

---

## Task 2: Audio Decoder (`audio_decoder.cpp`)

**Files:**
- Modify: `linux/audio_decoder.cpp`

The decoder uses miniaudio's built-in `ma_decoder` for file decoding and `libcurl` for URL downloads. No external codec packages needed.

- [ ] **Step 1: Implement `AudioDecoder::Decode`**

Replace `linux/audio_decoder.cpp` with:

```cpp
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
```

- [ ] **Step 2: Verify compilation**

```bash
cd example && flutter build linux --debug 2>&1 | grep -E "error:|warning:" | head -20
```

Expected: no errors. Warnings about unused variables in stubs are fine.

- [ ] **Step 3: Commit**

```bash
git add linux/audio_decoder.cpp
git commit -m "feat(linux): implement AudioDecoder (ma_decoder + libcurl + micro-fade)"
```

---

## Task 3: Loop Audio Engine — Core (Modes A/B, Play/Pause/Stop, Volume/Pan, BPM)

**Files:**
- Modify: `linux/loop_audio_engine.cpp`

This implements the fundamental loop engine without crossfade. Modes A and B cover the no-crossfade paths used for most files.

- [ ] **Step 1: Implement `loop_audio_engine.cpp` — core**

Replace the stub `linux/loop_audio_engine.cpp` with this full implementation. Read `windows/loop_audio_engine.cpp` for the Windows equivalent of each method.

```cpp
#include "loop_audio_engine.h"
#include "audio_decoder.h"
#include "bpm_detector.h"
#include <glib.h>
#include <cmath>
#include <cstring>
#include <algorithm>
#include <thread>

// ── Helpers ───────────────────────────────────────────────────────────────────

// Post a lambda to the GLib main loop. Safe to call from any thread.
// The lambda MUST guard with alive_ before touching engine state.
static void PostToMainThread(std::function<void()> fn) {
    auto* cb = new std::function<void()>(std::move(fn));
    g_idle_add([](gpointer data) -> gboolean {
        auto& fn = *static_cast<std::function<void()>*>(data);
        fn();
        delete &fn;
        return G_SOURCE_REMOVE;
    }, cb);
}

// ── Construction / Destruction ────────────────────────────────────────────────

LoopAudioEngine::LoopAudioEngine()
    : alive_(std::make_shared<std::atomic<bool>>(true)) {}

LoopAudioEngine::~LoopAudioEngine() { Dispose(); }

// ── SetState ──────────────────────────────────────────────────────────────────

void LoopAudioEngine::SetState(EngineState s) {
    state_ = s;
    if (onStateChange) onStateChange(s);
}

// ── InitDevice / TeardownDevice ───────────────────────────────────────────────

void LoopAudioEngine::InitDevice() {
    if (deviceInited_) return;
    ma_device_config cfg = ma_device_config_init(ma_device_type_playback);
    cfg.playback.format      = ma_format_f32;
    cfg.playback.channels    = channelCount_;
    cfg.sampleRate           = sampleRate_;
    cfg.dataCallback         = DataCallback;
    cfg.notificationCallback = NotificationCallback;
    cfg.pUserData            = this;

    if (ma_device_init(nullptr, &cfg, &device_) != MA_SUCCESS) {
        if (onError) onError("Failed to initialise audio device");
        return;
    }
    deviceInited_ = true;
}

void LoopAudioEngine::TeardownDevice() {
    if (!deviceInited_) return;
    ma_device_stop(&device_);    // blocks until callback thread exits
    ma_device_uninit(&device_);
    deviceInited_ = false;
}

// ── DataCallback (audio thread — no locks, no allocations) ───────────────────

void LoopAudioEngine::DataCallback(ma_device* pDev, void* pOut,
                                    const void*, ma_uint32 frameCount) {
    auto* self = static_cast<LoopAudioEngine*>(pDev->pUserData);
    float* out = static_cast<float*>(pOut);
    const int ch = static_cast<int>(pDev->playback.channels);

    if (!self->playing_.load(std::memory_order_relaxed) || self->fullPcm_.empty()) {
        memset(out, 0, frameCount * ch * sizeof(float));
        return;
    }

    const float* pcm       = self->fullPcm_.data();
    const auto   totalPcm  = static_cast<int64_t>(self->fullPcm_.size() / ch);
    const int64_t loopStart = static_cast<int64_t>(self->loopStartFrame_);
    const int64_t loopEnd   = static_cast<int64_t>(self->loopEndFrame_);
    const float   rate      = self->rate_.load(std::memory_order_relaxed);
    const float   vol       = self->volume_.load(std::memory_order_relaxed);
    const float   panL      = self->panLeft_.load(std::memory_order_relaxed);
    const float   panR      = self->panRight_.load(std::memory_order_relaxed);
    const int     xfFrames  = self->xfadeFrames_;

    float rmsAcc  = 0.0f;
    float peakAcc = 0.0f;

    for (ma_uint32 i = 0; i < frameCount; ++i) {
        // Wrap read position
        while (self->readPos_ >= static_cast<double>(loopEnd))
            self->readPos_ -= static_cast<double>(loopEnd - loopStart);

        const int64_t frame = static_cast<int64_t>(self->readPos_);
        const float   frac  = static_cast<float>(self->readPos_ - frame);

        // Next frame for interpolation (wraps within loop bounds)
        int64_t nextFrame = frame + 1;
        if (nextFrame >= loopEnd) nextFrame = loopStart;

        // Crossfade blend factor (0.0 = no blend, uses raw xfade ramps when > 0)
        float tailGain = 1.0f, headGain = 0.0f;
        int64_t headFrame = 0;
        int64_t headNext  = 0;
        if (xfFrames > 0 && frame >= loopEnd - xfFrames) {
            int xi = static_cast<int>(frame - (loopEnd - xfFrames));
            xi = std::min(xi, xfFrames - 1);
            tailGain  = self->xfadeOut_[xi];
            headGain  = self->xfadeIn_[xi];
            headFrame = loopStart + xi;
            headNext  = std::min(headFrame + 1, loopEnd - 1);
        }

        // Interpolate + blend + apply vol/pan
        for (int c = 0; c < ch; ++c) {
            const float s0 = pcm[frame    * ch + c];
            const float s1 = pcm[nextFrame * ch + c];
            float sample   = s0 + frac * (s1 - s0);

            if (headGain > 0.0f) {
                const float h0 = pcm[headFrame * ch + c];
                const float h1 = pcm[headNext  * ch + c];
                const float hs = h0 + frac * (h1 - h0);
                sample = sample * tailGain + hs * headGain;
            }

            sample *= vol;
            if (ch == 2) sample *= (c == 0 ? panL : panR);

            out[i * ch + c] = sample;
            rmsAcc  += sample * sample;
            peakAcc  = std::max(peakAcc, std::abs(sample));
        }

        self->readPos_ += rate;
    }

    // Amplitude emission (~20 Hz gate)
    const uint64_t prev = self->ampFrameCounter_.fetch_add(frameCount, std::memory_order_relaxed);
    if ((prev / kAmpEmitInterval) != ((prev + frameCount) / kAmpEmitInterval)) {
        const float rms  = std::sqrt(rmsAcc / static_cast<float>(frameCount * ch));
        const float peak = peakAcc;
        if (self->onAmplitude) {
            auto alive = self->alive_;
            auto* s    = self;
            PostToMainThread([s, alive, rms, peak] {
                if (!*alive) return;
                if (s->onAmplitude) s->onAmplitude(rms, peak);
            });
        }
    }
}

// ── NotificationCallback ──────────────────────────────────────────────────────

void LoopAudioEngine::NotificationCallback(const ma_device_notification* n) {
    auto* self = static_cast<LoopAudioEngine*>(n->pDevice->pUserData);
    if (n->type == ma_device_notification_type_rerouted) {
        // MUST NOT call ma_device_uninit/stop inline — deadlock.
        auto alive = self->alive_;
        auto* s = self;
        PostToMainThread([s, alive] {
            if (!*alive) return;
            s->HandleReroute();
        });
    }
}

// ── HandleReroute (main thread) ────────────────────────────────────────────────

void LoopAudioEngine::HandleReroute() {
    std::lock_guard<std::mutex> lock(stateMutex_);
    wasPlayingBeforeReroute_ = (state_ == EngineState::playing);
    TeardownDevice();
    InitDevice();
    if (wasPlayingBeforeReroute_ && deviceInited_) {
        playing_.store(true, std::memory_order_relaxed);
        ma_device_start(&device_);
        SetState(EngineState::playing);
    }
    if (onRouteChange) onRouteChange("unknown");
}

// ── LoadFile ──────────────────────────────────────────────────────────────────

bool LoopAudioEngine::LoadFile(const std::string& path) {
    StopBpmThread();
    {
        std::lock_guard<std::mutex> lock(stateMutex_);
        TeardownDevice();
        SetState(EngineState::loading);
    }

    // Decode on a background thread; commit result on main thread via callback.
    auto alive = alive_;
    auto* self = this;
    std::thread([self, alive, path] {
        DecodedAudio decoded;
        bool ok = AudioDecoder::Decode(path, decoded);
        PostToMainThread([self, alive, ok, decoded = std::move(decoded)]() mutable {
            if (!*alive) return;
            std::lock_guard<std::mutex> lock(self->stateMutex_);
            if (!ok) {
                self->SetState(EngineState::error);
                if (self->onError) self->onError("Failed to decode: " + std::string(""));
                return;
            }
            self->fullPcm_      = std::move(decoded.pcm);
            self->sampleRate_   = decoded.sampleRate;
            self->channelCount_ = decoded.channelCount;
            self->totalFrames_  = decoded.totalFrames;
            self->loopStartFrame_ = 0;
            self->loopEndFrame_   = decoded.totalFrames;
            self->fileDuration_   = static_cast<double>(decoded.totalFrames) / decoded.sampleRate;
            self->readPos_        = 0.0;
            self->xfadeFrames_    = 0;
            self->crossfadeDuration_ = 0.0;
            self->InitDevice();
            self->SetState(EngineState::ready);
            self->StartBpmThread();
        });
    }).detach();
    return true;
}

bool LoopAudioEngine::LoadUrl(const std::string& url) {
    StopBpmThread();
    {
        std::lock_guard<std::mutex> lock(stateMutex_);
        TeardownDevice();
        SetState(EngineState::loading);
    }
    auto alive = alive_;
    auto* self = this;
    std::thread([self, alive, url] {
        DecodedAudio decoded;
        bool ok = AudioDecoder::DecodeUrl(url, decoded);
        PostToMainThread([self, alive, ok, decoded = std::move(decoded)]() mutable {
            if (!*alive) return;
            std::lock_guard<std::mutex> lock(self->stateMutex_);
            if (!ok) {
                self->SetState(EngineState::error);
                if (self->onError) self->onError("URL download or decode failed");
                return;
            }
            self->fullPcm_      = std::move(decoded.pcm);
            self->sampleRate_   = decoded.sampleRate;
            self->channelCount_ = decoded.channelCount;
            self->totalFrames_  = decoded.totalFrames;
            self->loopStartFrame_ = 0;
            self->loopEndFrame_   = decoded.totalFrames;
            self->fileDuration_   = static_cast<double>(decoded.totalFrames) / decoded.sampleRate;
            self->readPos_        = 0.0;
            self->xfadeFrames_    = 0;
            self->crossfadeDuration_ = 0.0;
            self->InitDevice();
            self->SetState(EngineState::ready);
            self->StartBpmThread();
        });
    }).detach();
    return true;
}

// ── Playback control ──────────────────────────────────────────────────────────

void LoopAudioEngine::Play() {
    std::lock_guard<std::mutex> lock(stateMutex_);
    if (!deviceInited_ || fullPcm_.empty()) return;
    readPos_ = static_cast<double>(loopStartFrame_);
    playing_.store(true, std::memory_order_relaxed);
    ma_device_start(&device_);
    SetState(EngineState::playing);
}

void LoopAudioEngine::Pause() {
    std::lock_guard<std::mutex> lock(stateMutex_);
    if (state_ != EngineState::playing) return;
    playing_.store(false, std::memory_order_relaxed);
    ma_device_stop(&device_);
    SetState(EngineState::paused);
}

void LoopAudioEngine::Resume() {
    std::lock_guard<std::mutex> lock(stateMutex_);
    if (state_ != EngineState::paused) return;
    playing_.store(true, std::memory_order_relaxed);
    ma_device_start(&device_);
    SetState(EngineState::playing);
}

void LoopAudioEngine::Stop() {
    std::lock_guard<std::mutex> lock(stateMutex_);
    if (state_ == EngineState::idle || state_ == EngineState::loading) return;
    playing_.store(false, std::memory_order_relaxed);
    if (deviceInited_) ma_device_stop(&device_);
    readPos_ = static_cast<double>(loopStartFrame_);
    SetState(EngineState::stopped);
}

// ── Loop region ───────────────────────────────────────────────────────────────

bool LoopAudioEngine::SetLoopRegion(double startSecs, double endSecs) {
    std::lock_guard<std::mutex> lock(stateMutex_);
    if (fullPcm_.empty()) return false;
    const uint64_t s = static_cast<uint64_t>(startSecs * sampleRate_);
    const uint64_t e = static_cast<uint64_t>(endSecs   * sampleRate_);
    if (s >= e || e > totalFrames_) return false;
    // Stop device before mutating xfade ramps — DataCallback reads them lock-free.
    const bool wasPlaying = (state_ == EngineState::playing);
    if (deviceInited_) ma_device_stop(&device_);
    loopStartFrame_ = s;
    loopEndFrame_   = e;
    RebuildXfadeRamps();
    if (wasPlaying && deviceInited_) ma_device_start(&device_);
    return true;
}

// ── Crossfade ─────────────────────────────────────────────────────────────────

void LoopAudioEngine::SetCrossfadeDuration(double durationSecs) {
    std::lock_guard<std::mutex> lock(stateMutex_);
    // Stop device before rebuilding ramps — DataCallback reads them lock-free.
    const bool wasPlaying = (state_ == EngineState::playing);
    if (deviceInited_) ma_device_stop(&device_);
    crossfadeDuration_ = durationSecs;
    RebuildXfadeRamps();
    if (wasPlaying && deviceInited_) ma_device_start(&device_);
}

void LoopAudioEngine::RebuildXfadeRamps() {
    // Called with stateMutex_ held. Device must be stopped before calling if playing.
    if (crossfadeDuration_ <= 0.0) {
        xfadeFrames_ = 0;
        xfadeOut_.clear();
        xfadeIn_.clear();
        return;
    }
    const int64_t loopLen = static_cast<int64_t>(loopEndFrame_ - loopStartFrame_);
    int frames = static_cast<int>(crossfadeDuration_ * sampleRate_);
    frames = std::min(frames, static_cast<int>(loopLen / 2));
    if (frames <= 0) { xfadeFrames_ = 0; return; }
    xfadeFrames_ = frames;
    xfadeOut_.resize(frames);
    xfadeIn_.resize(frames);
    for (int i = 0; i < frames; ++i) {
        const float t = static_cast<float>(i) / static_cast<float>(frames);
        xfadeOut_[i] = std::cos(t * 3.14159265f * 0.5f);
        xfadeIn_[i]  = std::sin(t * 3.14159265f * 0.5f);
    }
}

// ── Volume / Pan / Rate ───────────────────────────────────────────────────────

void LoopAudioEngine::SetVolume(float v) {
    volume_.store(std::clamp(v, 0.0f, 1.0f), std::memory_order_relaxed);
}

void LoopAudioEngine::SetPan(float pan) {
    pan = std::clamp(pan, -1.0f, 1.0f);
    // Equal-power pan
    const float angle = (pan + 1.0f) * 0.5f * 3.14159265f * 0.5f;
    panLeft_.store(std::cos(angle),  std::memory_order_relaxed);
    panRight_.store(std::sin(angle), std::memory_order_relaxed);
}

void LoopAudioEngine::SetPlaybackRate(float r) {
    rate_.store(std::clamp(r, 0.25f, 4.0f), std::memory_order_relaxed);
}

// ── Seek ──────────────────────────────────────────────────────────────────────

bool LoopAudioEngine::Seek(double positionSecs) {
    std::lock_guard<std::mutex> lock(stateMutex_);
    if (fullPcm_.empty()) return false;
    const double newPos = std::clamp(positionSecs * sampleRate_,
                                     static_cast<double>(loopStartFrame_),
                                     static_cast<double>(loopEndFrame_ - 1));
    // Stop device before writing readPos_ — DataCallback reads it lock-free.
    const bool wasPlaying = (state_ == EngineState::playing);
    if (deviceInited_ && wasPlaying) ma_device_stop(&device_);
    readPos_ = newPos;
    if (deviceInited_ && wasPlaying) ma_device_start(&device_);
    return true;
}

// ── Duration / Position ───────────────────────────────────────────────────────

double LoopAudioEngine::GetDuration() const {
    std::lock_guard<std::mutex> lock(stateMutex_);
    return fileDuration_;
}

double LoopAudioEngine::GetCurrentPosition() const {
    std::lock_guard<std::mutex> lock(stateMutex_);
    return readPos_ / static_cast<double>(sampleRate_ > 0 ? sampleRate_ : 44100);
}

// ── BPM thread ────────────────────────────────────────────────────────────────

void LoopAudioEngine::StartBpmThread() {
    if (bpmRunning_.exchange(true)) return;
    bpmThread_ = std::thread([this] {
        // Snapshot PCM (thread-safe: fullPcm_ is not mutated after LoadFile commits)
        const float* pcm   = fullPcm_.data();
        const auto   frames = static_cast<int>(totalFrames_);
        const auto   ch     = static_cast<int>(channelCount_);
        const double sr     = static_cast<double>(sampleRate_);

        if (!bpmRunning_.load()) return;
        BpmResult result = BpmDetector::Detect(pcm, frames, ch, sr);

        if (!bpmRunning_.load()) return;
        auto alive = alive_;
        auto* self = this;
        PostToMainThread([self, alive, result] {
            if (!*alive) return;
            if (self->onBpmDetected) self->onBpmDetected(result);
        });
        bpmRunning_.store(false);
    });
    bpmThread_.detach();
}

void LoopAudioEngine::StopBpmThread() {
    bpmRunning_.store(false);
    // Thread is detached; setting the flag causes it to return early.
}

// ── Dispose ───────────────────────────────────────────────────────────────────

void LoopAudioEngine::Dispose() {
    *alive_ = false;     // Step 1: poison all pending g_idle_add lambdas
    StopBpmThread();
    {
        std::lock_guard<std::mutex> lock(stateMutex_);
        playing_.store(false, std::memory_order_relaxed);
        TeardownDevice();  // Step 2: joins audio thread
        SetState(EngineState::idle);
    }
    // Step 3: destructor of unique_ptr in plugin handler will free this object
}
```

- [ ] **Step 2: Verify compilation**

```bash
cd example && flutter build linux --debug 2>&1 | grep -E "error:" | head -20
```

Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add linux/loop_audio_engine.cpp
git commit -m "feat(linux): implement LoopAudioEngine core — modes A/B, play/pause/stop, volume/pan/rate, BPM"
```

---

## Task 4: Metronome Engine (`metronome_engine.cpp`)

**Files:**
- Modify: `linux/metronome_engine.cpp`

The metronome uses a second `ma_device` instance. Its callback reads cyclically from the pre-built bar buffer. Volume/pan are atomics applied live in the callback. `SetBpm`/`SetBeatsPerBar` stop the device before rebuilding.

- [ ] **Step 1: Implement `metronome_engine.cpp`**

Replace the stub with:

```cpp
#include "metronome_engine.h"
#include "audio_decoder.h"
#include <cmath>
#include <cstring>
#include <algorithm>
#include <chrono>
#include <glib.h>

static void PostToMainThread(std::function<void()> fn) {
    auto* cb = new std::function<void()>(std::move(fn));
    g_idle_add([](gpointer data) -> gboolean {
        auto& fn = *static_cast<std::function<void()>*>(data);
        fn();
        delete &fn;
        return G_SOURCE_REMOVE;
    }, cb);
}

MetronomeEngine::MetronomeEngine()
    : alive_(std::make_shared<std::atomic<bool>>(true)) {}

MetronomeEngine::~MetronomeEngine() { Dispose(); }

// ── DataCallback ─────────────────────────────────────────────────────────────

void MetronomeEngine::DataCallback(ma_device* pDev, void* pOut, const void*, ma_uint32 fc) {
    auto* self = static_cast<MetronomeEngine*>(pDev->pUserData);
    float* out = static_cast<float*>(pOut);
    const int ch = static_cast<int>(pDev->playback.channels);

    if (self->barPcm_.empty() || self->barFrames_ == 0) {
        memset(out, 0, fc * ch * sizeof(float));
        return;
    }

    const float* bar   = self->barPcm_.data();
    const auto   bFrames = static_cast<int64_t>(self->barFrames_);
    const float  vol   = self->volume_.load(std::memory_order_relaxed);
    const float  panL  = self->panLeft_.load(std::memory_order_relaxed);
    const float  panR  = self->panRight_.load(std::memory_order_relaxed);

    for (ma_uint32 i = 0; i < fc; ++i) {
        const int64_t frame = static_cast<int64_t>(self->readPos_) % bFrames;
        const int64_t next  = (frame + 1) % bFrames;
        const float   frac  = static_cast<float>(self->readPos_ - std::floor(self->readPos_));

        for (int c = 0; c < ch; ++c) {
            float s = bar[frame * ch + c] * (1.0f - frac) + bar[next * ch + c] * frac;
            s *= vol;
            if (ch == 2) s *= (c == 0 ? panL : panR);
            out[i * ch + c] = s;
        }
        self->readPos_ += 1.0;
        if (self->readPos_ >= static_cast<double>(bFrames))
            self->readPos_ -= static_cast<double>(bFrames);
    }
}

// ── DecodeBytes ───────────────────────────────────────────────────────────────

void MetronomeEngine::DecodeBytes(const std::vector<uint8_t>& data,
                                   const std::string& ext,
                                   std::vector<float>& out,
                                   uint32_t& sr, uint32_t& ch) {
    // Write to a temp file, decode via AudioDecoder::Decode, then delete.
    std::string tmp = "/tmp/fgl_metro_" + std::to_string(
        std::chrono::steady_clock::now().time_since_epoch().count()) + "." + ext;
    if (FILE* f = fopen(tmp.c_str(), "wb")) {
        fwrite(data.data(), 1, data.size(), f);
        fclose(f);
    }
    DecodedAudio decoded;
    if (AudioDecoder::Decode(tmp, decoded)) {
        out = std::move(decoded.pcm);
        sr  = decoded.sampleRate;
        ch  = decoded.channelCount;
    }
    unlink(tmp.c_str());
}

// ── MixInto ───────────────────────────────────────────────────────────────────

void MetronomeEngine::MixInto(std::vector<float>& dest, uint64_t destFrames,
                               const std::vector<float>& src, uint64_t srcFrames,
                               int channels, uint64_t offsetFrame) {
    const uint64_t copyFrames = std::min(srcFrames, destFrames - offsetFrame);
    for (uint64_t f = 0; f < copyFrames; ++f)
        for (int c = 0; c < channels; ++c)
            dest[(offsetFrame + f) * channels + c] += src[f * channels + c];
}

// ── BuildBarBuffer ────────────────────────────────────────────────────────────

bool MetronomeEngine::BuildBarBuffer() {
    if (clickPcm_.empty() || accentPcm_.empty()) return false;

    // Resample click/accent to device sample rate if needed (simple: use as-is,
    // assume caller provides appropriate sample rate — matches Android/iOS pattern).
    const double beatSecs = 60.0 / currentBpm_;
    const uint64_t beatFrames = static_cast<uint64_t>(beatSecs * clickSampleRate_);
    barFrames_ = beatFrames * static_cast<uint64_t>(currentBeatsPerBar_);

    barPcm_.assign(barFrames_ * clickChannels_, 0.0f);

    // Mix accent at frame 0
    const uint64_t accentFrames = accentPcm_.size() / clickChannels_;
    MixInto(barPcm_, barFrames_, accentPcm_, accentFrames, clickChannels_, 0);

    // Mix click at each beat position 1..N-1
    const uint64_t clickFrames = clickPcm_.size() / clickChannels_;
    for (int b = 1; b < currentBeatsPerBar_; ++b) {
        const uint64_t offset = static_cast<uint64_t>(b) * beatFrames;
        if (offset < barFrames_)
            MixInto(barPcm_, barFrames_, clickPcm_, clickFrames, clickChannels_, offset);
    }
    return true;
}

// ── Beat timer ────────────────────────────────────────────────────────────────

void MetronomeEngine::StartBeatTimer() {
    if (beatRunning_.exchange(true)) return;
    beatIndex_ = 0;
    beatThread_ = std::thread([this] {
        using Clock = std::chrono::steady_clock;
        const auto beatDuration = std::chrono::duration<double>(60.0 / currentBpm_);
        auto next = Clock::now() + beatDuration;

        while (beatRunning_.load()) {
            const int beat = beatIndex_;
            auto alive = alive_;
            auto* self = this;
            PostToMainThread([self, alive, beat] {
                if (!*alive) return;
                if (self->onBeatTick) self->onBeatTick(beat);
            });
            beatIndex_ = (beatIndex_ + 1) % currentBeatsPerBar_;
            std::this_thread::sleep_until(next);
            next += beatDuration;
        }
    });
}

void MetronomeEngine::StopBeatTimer() {
    beatRunning_.store(false);
    if (beatThread_.joinable()) beatThread_.join();
}

// ── RebuildAndRestart ─────────────────────────────────────────────────────────

void MetronomeEngine::RebuildAndRestart() {
    // Caller holds mutex_. Device must be stopped first.
    if (!isRunning_) return;
    if (deviceInited_) {
        ma_device_stop(&device_);
        ma_device_uninit(&device_);
        deviceInited_ = false;
    }
    StopBeatTimer();
    BuildBarBuffer();
    readPos_ = 0.0;

    ma_device_config cfg = ma_device_config_init(ma_device_type_playback);
    cfg.playback.format   = ma_format_f32;
    cfg.playback.channels = clickChannels_;
    cfg.sampleRate        = clickSampleRate_;
    cfg.dataCallback      = DataCallback;
    cfg.pUserData         = this;
    if (ma_device_init(nullptr, &cfg, &device_) == MA_SUCCESS) {
        deviceInited_ = true;
        ma_device_start(&device_);
    }
    StartBeatTimer();
}

// ── Public API ────────────────────────────────────────────────────────────────

void MetronomeEngine::Start(double bpm, int beatsPerBar,
                             const std::vector<uint8_t>& clickData,
                             const std::vector<uint8_t>& accentData,
                             const std::string& fileExtension) {
    std::lock_guard<std::mutex> lock(mutex_);
    currentBpm_         = bpm;
    currentBeatsPerBar_ = beatsPerBar;

    DecodeBytes(clickData,  fileExtension, clickPcm_,  clickSampleRate_, clickChannels_);
    DecodeBytes(accentData, fileExtension, accentPcm_, clickSampleRate_, clickChannels_);
    if (clickPcm_.empty()) {
        if (onError) onError("Failed to decode metronome click audio");
        return;
    }

    isRunning_ = true;
    RebuildAndRestart();
}

void MetronomeEngine::Stop() {
    std::lock_guard<std::mutex> lock(mutex_);
    isRunning_ = false;
    StopBeatTimer();
    if (deviceInited_) {
        ma_device_stop(&device_);
        ma_device_uninit(&device_);
        deviceInited_ = false;
    }
    readPos_ = 0.0;
}

void MetronomeEngine::SetBpm(double bpm) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!isRunning_) return;
    currentBpm_ = bpm;
    RebuildAndRestart();
}

void MetronomeEngine::SetBeatsPerBar(int bpb) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!isRunning_) return;
    currentBeatsPerBar_ = bpb;
    RebuildAndRestart();
}

void MetronomeEngine::SetVolume(float v) {
    volume_.store(std::clamp(v, 0.0f, 1.0f), std::memory_order_relaxed);
}

void MetronomeEngine::SetPan(float pan) {
    pan = std::clamp(pan, -1.0f, 1.0f);
    const float angle = (pan + 1.0f) * 0.5f * 3.14159265f * 0.5f;
    panLeft_.store(std::cos(angle),  std::memory_order_relaxed);
    panRight_.store(std::sin(angle), std::memory_order_relaxed);
}

void MetronomeEngine::Dispose() {
    *alive_ = false;
    Stop();
}
```

- [ ] **Step 2: Verify compilation**

```bash
cd example && flutter build linux --debug 2>&1 | grep -E "error:" | head -20
```

- [ ] **Step 3: Commit**

```bash
git add linux/metronome_engine.cpp
git commit -m "feat(linux): implement MetronomeEngine (ma_device, bar buffer, beat timer)"
```

---

## Task 5: Plugin Bridge (`flutter_gapless_loop_plugin.cpp`)

**Files:**
- Modify: `linux/flutter_gapless_loop_plugin.cpp`

The bridge uses GObject for Flutter registration and a C++ `PluginHandler` class for all method and event channel logic. Refer to `windows/flutter_gapless_loop_plugin.cpp` for the method handler logic — all method names, argument keys, and response types are identical.

- [ ] **Step 1: Implement the plugin bridge**

Replace `linux/flutter_gapless_loop_plugin.cpp` with:

```cpp
#include "include/flutter_gapless_loop/flutter_gapless_loop_plugin.h"
#include <flutter_linux/flutter_linux.h>
#include <glib.h>
#include <unistd.h>
#include <climits>
#include <cstring>
#include <map>
#include <memory>
#include <string>
#include <functional>
#include <atomic>

#include "loop_audio_engine.h"
#include "metronome_engine.h"

// ── PostToMainThread ──────────────────────────────────────────────────────────

static void PostToMainThread(std::function<void()> fn) {
    auto* cb = new std::function<void()>(std::move(fn));
    g_idle_add([](gpointer data) -> gboolean {
        auto& fn = *static_cast<std::function<void()>*>(data);
        fn();
        delete &fn;
        return G_SOURCE_REMOVE;
    }, cb);
}

// ── Argument helpers ──────────────────────────────────────────────────────────

static FlValue* Arg(FlValue* args, const char* key) {
    if (!args || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return nullptr;
    return fl_value_lookup_string(args, key);
}
static const char* ArgStr(FlValue* args, const char* key) {
    FlValue* v = Arg(args, key);
    if (!v || fl_value_get_type(v) != FL_VALUE_TYPE_STRING) return nullptr;
    return fl_value_get_string(v);
}
static double ArgDouble(FlValue* args, const char* key, double def = 0.0) {
    FlValue* v = Arg(args, key);
    if (!v) return def;
    if (fl_value_get_type(v) == FL_VALUE_TYPE_FLOAT) return fl_value_get_float(v);
    if (fl_value_get_type(v) == FL_VALUE_TYPE_INT)   return static_cast<double>(fl_value_get_int(v));
    return def;
}
static int64_t ArgInt(FlValue* args, const char* key, int64_t def = 0) {
    FlValue* v = Arg(args, key);
    if (!v) return def;
    if (fl_value_get_type(v) == FL_VALUE_TYPE_INT)   return fl_value_get_int(v);
    if (fl_value_get_type(v) == FL_VALUE_TYPE_FLOAT) return static_cast<int64_t>(fl_value_get_float(v));
    return def;
}
static std::vector<uint8_t> ArgBytes(FlValue* args, const char* key) {
    FlValue* v = Arg(args, key);
    if (!v || fl_value_get_type(v) != FL_VALUE_TYPE_UINT8_LIST) return {};
    const uint8_t* data = fl_value_get_uint8_list(v);
    const size_t   len  = fl_value_get_length(v);
    return std::vector<uint8_t>(data, data + len);
}

// ── Asset path helper ─────────────────────────────────────────────────────────

static std::string GetAssetPath(const std::string& assetKey) {
    char exePath[PATH_MAX];
    ssize_t len = readlink("/proc/self/exe", exePath, sizeof(exePath) - 1);
    if (len <= 0) return "";
    exePath[len] = '\0';
    std::string exe(exePath);
    auto sep = exe.rfind('/');
    if (sep == std::string::npos) return "";
    return exe.substr(0, sep) + "/data/flutter_assets/" + assetKey;
}

// ── FlValue map helper ────────────────────────────────────────────────────────

// Creates an FlValue map with the given string key/value pairs.
// Caller takes ownership. Use g_autoptr(FlValue) or pass to fl_event_channel_send.
static FlValue* MakeMap(
    std::initializer_list<std::pair<const char*, FlValue*>> entries) {
    FlValue* map = fl_value_new_map();
    for (auto& [k, v] : entries)
        fl_value_set_string_take(map, k, v);
    return map;
}

// ── PluginHandler ─────────────────────────────────────────────────────────────

class PluginHandler {
public:
    explicit PluginHandler(FlPluginRegistrar* registrar) {
        FlBinaryMessenger* messenger = fl_plugin_registrar_get_messenger(registrar);
        g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();

        loopMethodChannel_ = fl_method_channel_new(
            messenger, "flutter_gapless_loop", FL_METHOD_CODEC(codec));
        fl_method_channel_set_method_call_handler(
            loopMethodChannel_,
            [](FlMethodChannel*, FlMethodCall* call, gpointer ud) {
                static_cast<PluginHandler*>(ud)->HandleLoopCall(call);
            }, this, nullptr);

        loopEventChannel_ = fl_event_channel_new(
            messenger, "flutter_gapless_loop/events", FL_METHOD_CODEC(codec));
        fl_event_channel_set_stream_handlers(
            loopEventChannel_,
            [](FlEventChannel*, FlValue*, gpointer ud, GError**) -> FlMethodErrorResponse* {
                static_cast<PluginHandler*>(ud)->loopListening_ = true;
                return nullptr;
            },
            [](FlEventChannel*, FlValue*, gpointer ud) {
                static_cast<PluginHandler*>(ud)->loopListening_ = false;
            }, this, nullptr);

        metroMethodChannel_ = fl_method_channel_new(
            messenger, "flutter_gapless_loop/metronome", FL_METHOD_CODEC(codec));
        fl_method_channel_set_method_call_handler(
            metroMethodChannel_,
            [](FlMethodChannel*, FlMethodCall* call, gpointer ud) {
                static_cast<PluginHandler*>(ud)->HandleMetroCall(call);
            }, this, nullptr);

        metroEventChannel_ = fl_event_channel_new(
            messenger, "flutter_gapless_loop/metronome/events", FL_METHOD_CODEC(codec));
        fl_event_channel_set_stream_handlers(
            metroEventChannel_,
            [](FlEventChannel*, FlValue*, gpointer ud, GError**) -> FlMethodErrorResponse* {
                static_cast<PluginHandler*>(ud)->metroListening_ = true;
                return nullptr;
            },
            [](FlEventChannel*, FlValue*, gpointer ud) {
                static_cast<PluginHandler*>(ud)->metroListening_ = false;
            }, this, nullptr);
    }

    ~PluginHandler() {
        // Destroy all engines (alive_ already set false in Dispose calls)
        for (auto& [pid, eng] : engines_) {
            *eng->alive_ = false;
            eng->Dispose();
        }
        for (auto& [pid, met] : metronomes_) {
            *met->alive_ = false;
            met->Dispose();
        }
        g_object_unref(loopMethodChannel_);
        g_object_unref(loopEventChannel_);
        g_object_unref(metroMethodChannel_);
        g_object_unref(metroEventChannel_);
    }

    // ── Event emission ────────────────────────────────────────────────────────

    void SendLoopEvent(FlValue* event) {
        if (!loopListening_) { fl_value_unref(event); return; }
        fl_event_channel_send(loopEventChannel_, event, nullptr, nullptr);
        fl_value_unref(event);
    }
    void SendMetroEvent(FlValue* event) {
        if (!metroListening_) { fl_value_unref(event); return; }
        fl_event_channel_send(metroEventChannel_, event, nullptr, nullptr);
        fl_value_unref(event);
    }

    // ── Engine wiring ─────────────────────────────────────────────────────────

    LoopAudioEngine* GetOrCreateEngine(const std::string& pid) {
        auto it = engines_.find(pid);
        if (it != engines_.end()) return it->second.get();
        auto eng = std::make_unique<LoopAudioEngine>();
        WireEngineCallbacks(eng.get(), pid);
        auto* ptr = eng.get();
        engines_[pid] = std::move(eng);
        return ptr;
    }

    void WireEngineCallbacks(LoopAudioEngine* eng, const std::string& pid) {
        auto alive = eng->alive_;
        auto* self = this;

        // onStateChange / onError / onRouteChange are always called from the main
        // thread (inside PostToMainThread lambdas or Flutter method handlers).
        // Call SendLoopEvent directly — no redundant PostToMainThread round-trip.
        eng->onStateChange = [self, alive, pid](EngineState s) {
            if (!*alive) return;
            self->SendLoopEvent(MakeMap({
                {"type",     fl_value_new_string("stateChange")},
                {"state",    fl_value_new_string(EngineStateStr(s))},
                {"playerId", fl_value_new_string(pid.c_str())}
            }));
        };
        eng->onError = [self, alive, pid](const std::string& msg) {
            if (!*alive) return;
            self->SendLoopEvent(MakeMap({
                {"type",     fl_value_new_string("error")},
                {"message",  fl_value_new_string(msg.c_str())},
                {"playerId", fl_value_new_string(pid.c_str())}
            }));
        };
        eng->onRouteChange = [self, alive, pid](const std::string& reason) {
            if (!*alive) return;
            self->SendLoopEvent(MakeMap({
                {"type",     fl_value_new_string("routeChange")},
                {"reason",   fl_value_new_string(reason.c_str())},
                {"playerId", fl_value_new_string(pid.c_str())}
            }));
        };
        eng->onBpmDetected = [self, alive, pid](const BpmResult& r) {
            // Build beat list
            FlValue* beatsList = fl_value_new_list();
            for (double b : r.beats)
                fl_value_append_take(beatsList, fl_value_new_float(b));
            FlValue* barsList = fl_value_new_list();
            for (double b : r.bars)
                fl_value_append_take(barsList, fl_value_new_float(b));
            PostToMainThread([self, alive, pid, r, beatsList, barsList] {
                if (!*alive) { fl_value_unref(beatsList); fl_value_unref(barsList); return; }
                self->SendLoopEvent(MakeMap({
                    {"type",        fl_value_new_string("bpmDetected")},
                    {"playerId",    fl_value_new_string(pid.c_str())},
                    {"bpm",         fl_value_new_float(r.bpm)},
                    {"confidence",  fl_value_new_float(r.confidence)},
                    {"beats",       beatsList},
                    {"beatsPerBar", fl_value_new_int(r.beatsPerBar)},
                    {"bars",        barsList}
                }));
            });
        };
        eng->onAmplitude = [self, alive, pid](float rms, float peak) {
            PostToMainThread([self, alive, pid, rms, peak] {
                if (!*alive) return;
                self->SendLoopEvent(MakeMap({
                    {"type",     fl_value_new_string("amplitude")},
                    {"playerId", fl_value_new_string(pid.c_str())},
                    {"rms",      fl_value_new_float(rms)},
                    {"peak",     fl_value_new_float(peak)}
                }));
            });
        };
    }

    MetronomeEngine* GetOrCreateMetronome(const std::string& pid) {
        auto it = metronomes_.find(pid);
        if (it != metronomes_.end()) return it->second.get();
        auto met = std::make_unique<MetronomeEngine>();
        WireMetroCallbacks(met.get(), pid);
        auto* ptr = met.get();
        metronomes_[pid] = std::move(met);
        return ptr;
    }

    void WireMetroCallbacks(MetronomeEngine* met, const std::string& pid) {
        auto alive = met->alive_;
        auto* self = this;
        met->onBeatTick = [self, alive, pid](int beat) {
            PostToMainThread([self, alive, pid, beat] {
                if (!*alive) return;
                self->SendMetroEvent(MakeMap({
                    {"type",     fl_value_new_string("beatTick")},
                    {"playerId", fl_value_new_string(pid.c_str())},
                    {"beat",     fl_value_new_int(beat)}
                }));
            });
        };
        met->onError = [self, alive, pid](const std::string& msg) {
            PostToMainThread([self, alive, pid, msg] {
                if (!*alive) return;
                self->SendMetroEvent(MakeMap({
                    {"type",     fl_value_new_string("error")},
                    {"playerId", fl_value_new_string(pid.c_str())},
                    {"message",  fl_value_new_string(msg.c_str())}
                }));
            });
        };
    }

    // ── Loop method handler ───────────────────────────────────────────────────

    void HandleLoopCall(FlMethodCall* call) {
        const char* method = fl_method_call_get_name(call);
        FlValue*    args   = fl_method_call_get_args(call);

        // clearAll — handle before playerId guard (hot-restart cleanup).
        // Loop channel clearAll clears ONLY loop engines (not metronomes).
        if (strcmp(method, "clearAll") == 0) {
            for (auto& [pid, eng] : engines_) { *eng->alive_ = false; eng->Dispose(); }
            engines_.clear();
            g_autoptr(FlMethodSuccessResponse) resp =
                fl_method_success_response_new(fl_value_new_null());
            fl_method_call_respond(call, FL_METHOD_RESPONSE(resp), nullptr);
            return;
        }

        const char* pid_c = ArgStr(args, "playerId");
        if (!pid_c) {
            g_autoptr(FlMethodErrorResponse) resp = fl_method_error_response_new(
                "INVALID_ARGS", "'playerId' is required", nullptr);
            fl_method_call_respond(call, FL_METHOD_RESPONSE(resp), nullptr);
            return;
        }
        const std::string pid(pid_c);

        auto Respond = [&](FlValue* val = nullptr) {
            g_autoptr(FlMethodSuccessResponse) resp =
                fl_method_success_response_new(val ? val : fl_value_new_null());
            fl_method_call_respond(call, FL_METHOD_RESPONSE(resp), nullptr);
            if (val) fl_value_unref(val);
        };
        auto Error = [&](const char* code, const char* msg) {
            g_autoptr(FlMethodErrorResponse) resp =
                fl_method_error_response_new(code, msg, nullptr);
            fl_method_call_respond(call, FL_METHOD_RESPONSE(resp), nullptr);
        };

        if (strcmp(method, "load") == 0) {
            const char* key = ArgStr(args, "assetKey");
            if (!key) return Error("INVALID_ARGS", "assetKey required");
            std::string assetPath = GetAssetPath(key);
            if (assetPath.empty()) return Error("LOAD_FAILED", "Could not resolve asset path");
            GetOrCreateEngine(pid)->LoadFile(assetPath);
            Respond();
        } else if (strcmp(method, "loadFile") == 0) {
            const char* path = ArgStr(args, "path");
            if (!path) return Error("INVALID_ARGS", "path required");
            GetOrCreateEngine(pid)->LoadFile(path);
            Respond();
        } else if (strcmp(method, "loadUrl") == 0) {
            const char* url = ArgStr(args, "url");
            if (!url) return Error("INVALID_ARGS", "url required");
            GetOrCreateEngine(pid)->LoadUrl(url);
            Respond();
        } else if (strcmp(method, "play") == 0) {
            auto it = engines_.find(pid);
            if (it != engines_.end()) it->second->Play();
            Respond();
        } else if (strcmp(method, "pause") == 0) {
            auto it = engines_.find(pid);
            if (it != engines_.end()) it->second->Pause();
            Respond();
        } else if (strcmp(method, "resume") == 0) {
            auto it = engines_.find(pid);
            if (it != engines_.end()) it->second->Resume();
            Respond();
        } else if (strcmp(method, "stop") == 0) {
            auto it = engines_.find(pid);
            if (it != engines_.end()) it->second->Stop();
            Respond();
        } else if (strcmp(method, "setLoopRegion") == 0) {
            double start = ArgDouble(args, "start");
            double end   = ArgDouble(args, "end");
            auto it = engines_.find(pid);
            if (it != engines_.end()) it->second->SetLoopRegion(start, end);
            Respond();
        } else if (strcmp(method, "setCrossfadeDuration") == 0) {
            double dur = ArgDouble(args, "duration");
            auto it = engines_.find(pid);
            if (it != engines_.end()) it->second->SetCrossfadeDuration(dur);
            Respond();
        } else if (strcmp(method, "setVolume") == 0) {
            float vol = static_cast<float>(ArgDouble(args, "volume", 1.0));
            auto it = engines_.find(pid);
            if (it != engines_.end()) it->second->SetVolume(vol);
            Respond();
        } else if (strcmp(method, "setPan") == 0) {
            float pan = static_cast<float>(ArgDouble(args, "pan", 0.0));
            auto it = engines_.find(pid);
            if (it != engines_.end()) it->second->SetPan(pan);
            Respond();
        } else if (strcmp(method, "setPlaybackRate") == 0) {
            float rate = static_cast<float>(ArgDouble(args, "rate", 1.0));
            auto it = engines_.find(pid);
            if (it != engines_.end()) it->second->SetPlaybackRate(rate);
            Respond();
        } else if (strcmp(method, "seek") == 0) {
            double pos = ArgDouble(args, "position");
            auto it = engines_.find(pid);
            if (it != engines_.end()) it->second->Seek(pos);
            Respond();
        } else if (strcmp(method, "getDuration") == 0) {
            double dur = 0.0;
            auto it = engines_.find(pid);
            if (it != engines_.end()) dur = it->second->GetDuration();
            Respond(fl_value_new_float(dur));
        } else if (strcmp(method, "getCurrentPosition") == 0) {
            double pos = 0.0;
            auto it = engines_.find(pid);
            if (it != engines_.end()) pos = it->second->GetCurrentPosition();
            Respond(fl_value_new_float(pos));
        } else if (strcmp(method, "dispose") == 0) {
            auto it = engines_.find(pid);
            if (it != engines_.end()) {
                *it->second->alive_ = false;
                it->second->Dispose();
                engines_.erase(it);
            }
            Respond();
        } else {
            g_autoptr(FlMethodNotImplementedResponse) resp =
                fl_method_not_implemented_response_new();
            fl_method_call_respond(call, FL_METHOD_RESPONSE(resp), nullptr);
        }
    }

    // ── Metronome method handler ──────────────────────────────────────────────

    void HandleMetroCall(FlMethodCall* call) {
        const char* method = fl_method_call_get_name(call);
        FlValue*    args   = fl_method_call_get_args(call);

        // Metro channel clearAll clears ONLY metronomes (not loop engines).
        if (strcmp(method, "clearAll") == 0) {
            for (auto& [pid, met] : metronomes_) { *met->alive_ = false; met->Dispose(); }
            metronomes_.clear();
            g_autoptr(FlMethodSuccessResponse) resp =
                fl_method_success_response_new(fl_value_new_null());
            fl_method_call_respond(call, FL_METHOD_RESPONSE(resp), nullptr);
            return;
        }

        const char* pid_c = ArgStr(args, "playerId");
        if (!pid_c) {
            g_autoptr(FlMethodErrorResponse) resp = fl_method_error_response_new(
                "INVALID_ARGS", "'playerId' is required", nullptr);
            fl_method_call_respond(call, FL_METHOD_RESPONSE(resp), nullptr);
            return;
        }
        const std::string pid(pid_c);

        auto Respond = [&](FlValue* val = nullptr) {
            g_autoptr(FlMethodSuccessResponse) resp =
                fl_method_success_response_new(val ? val : fl_value_new_null());
            fl_method_call_respond(call, FL_METHOD_RESPONSE(resp), nullptr);
            if (val) fl_value_unref(val);
        };
        auto Error = [&](const char* code, const char* msg) {
            g_autoptr(FlMethodErrorResponse) resp =
                fl_method_error_response_new(code, msg, nullptr);
            fl_method_call_respond(call, FL_METHOD_RESPONSE(resp), nullptr);
        };

        if (strcmp(method, "start") == 0) {
            double bpm       = ArgDouble(args, "bpm", 120.0);
            int64_t bpb      = ArgInt(args, "beatsPerBar", 4);
            auto click       = ArgBytes(args, "click");
            auto accent      = ArgBytes(args, "accent");
            const char* ext  = ArgStr(args, "extension");
            if (click.empty() || accent.empty())
                return Error("INVALID_ARGS", "click and accent bytes required");
            GetOrCreateMetronome(pid)->Start(bpm, static_cast<int>(bpb),
                click, accent, ext ? ext : "wav");
            Respond();
        } else if (strcmp(method, "stop") == 0) {
            auto it = metronomes_.find(pid);
            if (it != metronomes_.end()) it->second->Stop();
            Respond();
        } else if (strcmp(method, "setBpm") == 0) {
            double bpm = ArgDouble(args, "bpm", 120.0);
            auto it = metronomes_.find(pid);
            if (it != metronomes_.end()) it->second->SetBpm(bpm);
            Respond();
        } else if (strcmp(method, "setBeatsPerBar") == 0) {
            int64_t bpb = ArgInt(args, "beatsPerBar", 4);
            auto it = metronomes_.find(pid);
            if (it != metronomes_.end()) it->second->SetBeatsPerBar(static_cast<int>(bpb));
            Respond();
        } else if (strcmp(method, "setVolume") == 0) {
            float vol = static_cast<float>(ArgDouble(args, "volume", 1.0));
            auto it = metronomes_.find(pid);
            if (it != metronomes_.end()) it->second->SetVolume(vol);
            Respond();
        } else if (strcmp(method, "setPan") == 0) {
            float pan = static_cast<float>(ArgDouble(args, "pan", 0.0));
            auto it = metronomes_.find(pid);
            if (it != metronomes_.end()) it->second->SetPan(pan);
            Respond();
        } else if (strcmp(method, "dispose") == 0) {
            auto it = metronomes_.find(pid);
            if (it != metronomes_.end()) {
                *it->second->alive_ = false;
                it->second->Dispose();
                metronomes_.erase(it);
            }
            Respond();
        } else {
            g_autoptr(FlMethodNotImplementedResponse) resp =
                fl_method_not_implemented_response_new();
            fl_method_call_respond(call, FL_METHOD_RESPONSE(resp), nullptr);
        }
    }

private:
    FlMethodChannel* loopMethodChannel_  = nullptr;
    FlEventChannel*  loopEventChannel_   = nullptr;
    FlMethodChannel* metroMethodChannel_ = nullptr;
    FlEventChannel*  metroEventChannel_  = nullptr;
    bool loopListening_  = false;
    bool metroListening_ = false;
    std::map<std::string, std::unique_ptr<LoopAudioEngine>>  engines_;
    std::map<std::string, std::unique_ptr<MetronomeEngine>>  metronomes_;
};

// ── GObject wrapper ───────────────────────────────────────────────────────────

struct _FlutterGaplessLoopPlugin {
    GObject      parent_instance;
    PluginHandler* handler = nullptr;
};

G_DEFINE_TYPE(FlutterGaplessLoopPlugin, flutter_gapless_loop_plugin, G_TYPE_OBJECT)

static void flutter_gapless_loop_plugin_dispose(GObject* object) {
    FlutterGaplessLoopPlugin* self = FLUTTER_GAPLESS_LOOP_PLUGIN(object);
    delete self->handler;
    self->handler = nullptr;
    G_OBJECT_CLASS(flutter_gapless_loop_plugin_parent_class)->dispose(object);
}

static void flutter_gapless_loop_plugin_class_init(FlutterGaplessLoopPluginClass* klass) {
    G_OBJECT_CLASS(klass)->dispose = flutter_gapless_loop_plugin_dispose;
}

static void flutter_gapless_loop_plugin_init(FlutterGaplessLoopPlugin*) {}

void flutter_gapless_loop_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
    FlutterGaplessLoopPlugin* plugin = FLUTTER_GAPLESS_LOOP_PLUGIN(
        g_object_new(flutter_gapless_loop_plugin_get_type(), nullptr));
    plugin->handler = new PluginHandler(registrar);
    g_object_unref(plugin);
}
```

- [ ] **Step 2: Verify full compilation**

```bash
cd example && flutter build linux --debug 2>&1 | tail -10
```

Expected: `✓ Built build/linux/x64/debug/bundle/flutter_gapless_loop_example` (or similar success line). No errors.

- [ ] **Step 3: Smoke-test the example app**

```bash
cd example && flutter run -d linux
```

Open the app. Pick an audio file. Verify:
- State shows "Loading…" then "Ready"
- Play button starts audio
- Pause/Stop work
- BPM is detected and displayed

- [ ] **Step 4: Commit**

```bash
git add linux/flutter_gapless_loop_plugin.cpp
git commit -m "feat(linux): implement plugin bridge — GObject + PluginHandler, all method/event channels"
```

---

## Task 6: Docs and Version Bump

**Files:**
- Modify: `pubspec.yaml`
- Modify: `README.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Bump version to 0.0.9 in `pubspec.yaml`**

Change `version: 0.0.7` (or current value) to `version: 0.0.9`.

- [ ] **Step 2: Add Linux to README platform table**

In `README.md`, find the platform table and add a Linux row:

```markdown
| Linux    | ✅      | miniaudio 0.11.21 (PipeWire / PulseAudio / ALSA) + libcurl (Ubuntu 20.04+) |
```

Also update the installation snippet:
```yaml
  flutter_gapless_loop: ^0.0.9
```

And add Linux to the Important Notes section:
```
- **Minimum Linux:** Ubuntu 20.04+ (glibc 2.31+). `libcurl` must be installed (`sudo apt install libcurl4-openssl-dev` for development; it ships by default on most desktop distros).
```

- [ ] **Step 3: Add 0.0.9 entry to `CHANGELOG.md`**

Insert at the top (before the current first entry):

```markdown
## 0.0.9

### New platforms

* **Linux support.** Full implementation using [miniaudio](https://miniaud.io) v0.11.21 (PipeWire / PulseAudio / ALSA auto-selected at runtime) for audio output and decode, plus `libcurl` for URL loading. All four playback modes (full/region × with/without crossfade), BPM/time-signature detection, equal-power crossfade, metronome, real-time amplitude metering, stereo pan, volume, seek, and playback rate are supported. Minimum: Ubuntu 20.04+ / glibc 2.31+.
```

- [ ] **Step 4: Verify the example still builds**

```bash
cd example && flutter build linux --debug 2>&1 | tail -5
```

- [ ] **Step 5: Commit**

```bash
git add pubspec.yaml README.md CHANGELOG.md
git commit -m "feat(linux): add Linux platform — version bump to 0.0.9, docs update"
```

---

## Task 7: Integration Verification

- [ ] **Step 1: Full release build**

```bash
cd example && flutter build linux --release 2>&1 | tail -10
```

Expected: success with no errors.

- [ ] **Step 2: End-to-end feature checklist**

Run `flutter run -d linux` and verify each feature:

- [ ] Load audio file (WAV, MP3, FLAC) via file picker → state: ready
- [ ] Play → audio heard, progress bar advances
- [ ] Pause → audio stops, state: paused
- [ ] Resume → audio resumes from same position
- [ ] Stop → position resets
- [ ] Loop region sliders → loop plays within bounds
- [ ] Crossfade slider → smooth transition at loop boundary
- [ ] Volume slider → level changes
- [ ] Pan slider → stereo position changes
- [ ] BPM display → auto-detected BPM shown after load
- [ ] Metronome card → starts, beat dots animate, BPM slider works
- [ ] Hot restart (`r` in terminal) → app recovers without crash
- [ ] Headphone unplug (if hardware available) → route change event logged

- [ ] **Step 3: Final commit**

```bash
git add -A
git commit -m "feat(linux): Linux platform implementation complete — miniaudio + libcurl"
```
