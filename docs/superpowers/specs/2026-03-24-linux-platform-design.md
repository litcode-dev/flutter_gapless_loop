# Linux Platform Implementation — Design Spec

**Date:** 2026-03-24
**Plugin:** flutter_gapless_loop
**Scope:** Add Linux as a fully supported platform, feature-parity with Windows.

---

## 1. Goals

- Sample-accurate gapless looping on Linux desktop.
- Full feature parity with the Windows implementation: all 4 playback modes, BPM/time-signature detection, equal-power crossfade, metronome, amplitude metering, stereo pan, volume, seek, playback rate, URL loading.
- Zero mandatory system audio library dependencies at link time (miniaudio dlopen()s backends at runtime).
- Single new dependency for URL loading: `libcurl` (universally available via `pkg-config`).
- No changes to the Dart API layer.

---

## 2. Audio Library: miniaudio

**Choice:** [miniaudio](https://miniaud.io) — single-header C library, vendored at `linux/third_party/miniaudio.h`.

**Why:**
- Zero system package dependencies for audio output; miniaudio dlopen()s PipeWire, PulseAudio, or ALSA at runtime in preference order.
- Built-in decoders (dr_wav, dr_mp3, dr_flac, stb_vorbis) cover WAV, MP3, FLAC, OGG — same format support as MediaFoundation on Windows.
- Pull/callback model maps cleanly to the 4-mode loop architecture.
- MIT licence; single file to vendor.

**Activation:** One `.cpp` file defines `MINIAUDIO_IMPLEMENTATION` before the include. All other files include the header without the define.

---

## 3. File Structure

```
linux/
├── CMakeLists.txt
├── include/flutter_gapless_loop/
│   └── flutter_gapless_loop_plugin.h     # GObject C registration header
├── flutter_gapless_loop_plugin.cpp       # Plugin bridge (GLib/GObject + C++ handler)
├── loop_audio_engine.h                   # Public engine API (mirrors windows/)
├── loop_audio_engine.cpp                 # miniaudio playback, 4 modes
├── audio_decoder.h                       # DecodedAudio struct + static decode API
├── audio_decoder.cpp                     # ma_decoder + libcurl URL download
├── bpm_detector.h                        # Copied verbatim from windows/
├── bpm_detector.cpp                      # Copied verbatim from windows/
├── crossfade_engine.h                    # Copied verbatim from windows/ (header-only)
├── metronome_engine.h                    # Separate ma_device metronome
├── metronome_engine.cpp
└── third_party/
    └── miniaudio.h                       # Vendored single-header (~5 MB)
```

**Verbatim copies from `windows/`** (pure C++ math, no OS calls):
- `bpm_detector.h/.cpp` — Ellis (2007) beat tracker
- `crossfade_engine.h` — header-only equal-power ramps

---

## 4. Build System (`CMakeLists.txt`)

```cmake
cmake_minimum_required(VERSION 3.14)
project(flutter_gapless_loop_plugin)

set(CMAKE_CXX_STANDARD 17)

find_package(PkgConfig REQUIRED)
pkg_check_modules(CURL REQUIRED libcurl)

add_library(flutter_gapless_loop_plugin SHARED
  flutter_gapless_loop_plugin.cpp
  loop_audio_engine.cpp
  audio_decoder.cpp
  bpm_detector.cpp
  metronome_engine.cpp
)

target_include_directories(flutter_gapless_loop_plugin PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/third_party"
  ${CURL_INCLUDE_DIRS}
)

target_link_libraries(flutter_gapless_loop_plugin PUBLIC
  flutter
  PkgConfig::CURL
  dl        # miniaudio dlopen()s audio backends
  pthread   # std::thread, std::mutex
  m         # math (miniaudio)
)

target_compile_definitions(flutter_gapless_loop_plugin PRIVATE
  FLUTTER_PLUGIN_IMPL
)
```

---

## 5. Core Engine (`loop_audio_engine`)

### 5.1 miniaudio Device

One `ma_device` per `LoopAudioEngine` instance. Configured as output-only, float32, stereo (or native channel count). The device's `data_callback` is the sole write path for PCM data.

```cpp
ma_device_config cfg = ma_device_config_init(ma_device_type_playback);
cfg.playback.format   = ma_format_f32;
cfg.playback.channels = channelCount_;
cfg.sampleRate        = sampleRate_;
cfg.dataCallback      = DataCallback;
cfg.notificationCallback = NotificationCallback;
cfg.pUserData         = this;
ma_device_init(nullptr, &cfg, &device_);
```

### 5.2 Data Callback (loop logic)

All four playback modes are implemented inside the callback by advancing `readPos_` (a `double` for sub-frame accuracy with rate ≠ 1.0):

```
Mode A — full file, no crossfade:
  copy frames [readPos_, readPos_+frameCount), wrap at totalFrames_

Mode B — loop region, no crossfade:
  copy frames, wrap at loopEndFrame_, restart at loopStartFrame_

Mode C — full file + crossfade:
  copy frames; when within xfadeFrames_ of totalFrames_,
  blend tail PCM (fade-out) + head PCM (fade-in) sample-by-sample

Mode D — loop region + crossfade:
  same as C but bounds are loopStartFrame_ / loopEndFrame_
```

Linear interpolation between adjacent samples handles fractional `readPos_` (non-unity rate).

### 5.3 Playback Rate

`readPos_` advances by `rate_` per output frame. At `rate_ = 1.0` this is sample-accurate. At other rates, linear interpolation produces a speed change with corresponding pitch change — matching Windows `SetFrequencyRatio` behaviour.

### 5.4 Amplitude Metering

RMS and peak are accumulated inside the callback. A `std::atomic<uint64_t>` frame counter gates emission to ~20 Hz via `g_idle_add`.

### 5.5 Device Change (Reroute)

`NotificationCallback` fires with `ma_device_notification_type_rerouted` when the system default output changes. Handler: stop device → `ma_device_uninit` → reinitialise with `ma_device_init` → restart if was playing → emit `routeChange` event via `PostToMainThread`.

### 5.6 State Machine

Identical to Windows: `EngineState` enum (idle, loading, ready, playing, paused, stopped, error). All public methods lock `std::mutex stateMutex_` before reading or writing state.

---

## 6. Audio Decoder (`audio_decoder`)

### 6.1 File Decode

```cpp
struct DecodedAudio {
    std::vector<float> pcm;   // interleaved float32 [-1.0, 1.0]
    uint32_t sampleRate   = 0;
    uint32_t channelCount = 0;
    uint64_t totalFrames  = 0;
};

static bool Decode(const std::string& path, DecodedAudio& out);
static void ApplyMicroFade(std::vector<float>& pcm,
                            uint32_t sampleRate,
                            uint32_t channelCount);
```

Implemented with `ma_decoder_init_file` → `ma_decoder_get_length_in_pcm_frames` (pre-allocate) → `ma_decoder_read_pcm_frames` → `ma_decoder_uninit`.

### 6.2 URL Download

```cpp
static bool DecodeUrl(const std::string& url, DecodedAudio& out);
```

Uses `libcurl` in easy/synchronous mode:
1. Generate UUID temp path under `/tmp/fgl_<uuid>.<ext>`.
2. `curl_easy_setopt(CURLOPT_URL, ...)` + `CURLOPT_WRITEDATA` to file handle.
3. `curl_easy_perform`.
4. On success: `Decode(tempPath, out)`. Always `unlink(tempPath)` in cleanup.

### 6.3 Micro-Fade

5 ms linear ramp applied in-place at both ends of `pcm` after decode. Identical math to Windows `ApplyMicroFade`.

---

## 7. Metronome Engine (`metronome_engine`)

A second, independent `ma_device` instance. The bar buffer (accent + clicks + silence) is pre-generated identically to Windows and Android: `buildBarBuffer(bpm, beatsPerBar, clickPcm, accentPcm)`. The callback reads cyclically: `readPos_ % barFrames_` — no loop flag, just modular arithmetic.

Beat tick timer: `std::thread` + `std::chrono::steady_clock`, same as Windows. Tick fires `PostToMainThread` with beat index.

`SetBpm` / `SetBeatsPerBar`: rebuild bar buffer, reset `readPos_` to 0, resume. No-op if not started.

`SetVolume` / `SetPan`: apply equal-power pan gains to the bar buffer write path in the callback (scale left/right channels).

---

## 8. Plugin Bridge (`flutter_gapless_loop_plugin`)

### 8.1 Registration

```c
// include/flutter_gapless_loop/flutter_gapless_loop_plugin.h
G_BEGIN_DECLS
#define FLUTTER_GAPLESS_LOOP_PLUGIN(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), \
   flutter_gapless_loop_plugin_get_type(), FlutterGaplessLoopPlugin))
typedef struct _FlutterGaplessLoopPlugin FlutterGaplessLoopPlugin;
GType flutter_gapless_loop_plugin_get_type();
void flutter_gapless_loop_plugin_register_with_registrar(
    FlPluginRegistrar* registrar);
G_END_DECLS
```

The `_FlutterGaplessLoopPlugin` struct embeds a pointer to a C++ handler object that owns the engine maps and channel handles. GObject lifecycle (`dispose`) calls the C++ handler destructor.

### 8.2 Channels

Registered identically to all other platforms:

| Channel | Type |
|---------|------|
| `flutter_gapless_loop` | `FlMethodChannel` |
| `flutter_gapless_loop/events` | `FlEventChannel` |
| `flutter_gapless_loop/metronome` | `FlMethodChannel` |
| `flutter_gapless_loop/metronome/events` | `FlEventChannel` |

### 8.3 Method Handlers

All method names, argument keys, and return types are identical to Windows. The handler class holds:

```cpp
std::map<std::string, std::unique_ptr<LoopAudioEngine>>  engines_;
std::map<std::string, std::unique_ptr<MetronomeEngine>>  metronomes_;
FlEventSink* eventSink_     = nullptr;
FlEventSink* metroSink_     = nullptr;
```

### 8.4 Main-Thread Marshalling

Replaces Windows `PostMessage` + window proc delegate:

```cpp
void PostToMainThread(std::function<void()> fn) {
    auto* cb = new std::function<void()>(std::move(fn));
    g_idle_add([](gpointer data) -> gboolean {
        auto& fn = *static_cast<std::function<void()>*>(data);
        fn();
        delete &fn;
        return G_SOURCE_REMOVE;
    }, cb);
}
```

All engine callbacks (state change, error, BPM, amplitude, route change, beat tick) call `PostToMainThread` before writing to any `FlEventSink`.

### 8.5 Asset Path Resolution

```cpp
char exePath[PATH_MAX];
ssize_t len = readlink("/proc/self/exe", exePath, sizeof(exePath) - 1);
exePath[len] = '\0';
std::string exeDir = std::string(exePath).substr(0, lastSlash);
std::string assetPath = exeDir + "/data/flutter_assets/" + assetKey;
```

Direct parallel to Windows `GetModuleFileNameW` approach.

### 8.6 Event Encoding

`FlValue` (GLib-based) replaces `EncodableMap`. Helper:

```cpp
FlValue* MakeMap(std::initializer_list<std::pair<const char*, FlValue*>> entries);
```

Event structure is identical to Windows (same keys: `type`, `state`, `playerId`, `bpm`, etc.).

---

## 9. pubspec.yaml & README Changes

**`pubspec.yaml`** — add to `flutter.plugin.platforms`:
```yaml
linux:
  pluginClass: FlutterGaplessLoopPlugin
```

**`README.md`** — add Linux row to platform table:
```
| Linux    | ✅      | miniaudio (PipeWire/PulseAudio/ALSA) + libcurl (Ubuntu 20.04+) |
```

**Version** — bump to `0.0.8` in `pubspec.yaml` and add `## 0.0.8` entry in `CHANGELOG.md`.

---

## 10. What Does NOT Change

- Dart API (`lib/`) — no changes.
- iOS, Android, macOS, Windows implementations — no changes.
- Method channel names, argument keys, event types — identical on Linux.
- `BpmResult`, `DecodedAudio` structs — same fields, same semantics.

---

## 11. Minimum Requirements

| Requirement | Value |
|-------------|-------|
| CMake | 3.14+ |
| C++ standard | 17 |
| Flutter | 3.27.0+ |
| libcurl | any recent version (pkg-config) |
| Linux distro | Ubuntu 20.04+ (or equivalent glibc 2.31+) |
| Audio backend | PipeWire, PulseAudio, or ALSA (miniaudio auto-selects) |
