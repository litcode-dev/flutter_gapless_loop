# Linux Platform Implementation — Design Spec

**Date:** 2026-03-24
**Plugin:** flutter_gapless_loop
**Scope:** Add Linux as a fully supported platform, feature-parity with Windows.

---

## 1. Goals

- Sample-accurate gapless looping on Linux desktop.
- Full feature parity with the Windows implementation: all 4 playback modes, BPM/time-signature detection, equal-power crossfade, metronome, amplitude metering, stereo pan, volume, seek, playback rate, URL loading.
- Zero mandatory system audio library link-time dependencies (miniaudio dlopen()s backends at runtime).
- Single new dependency for URL loading: `libcurl` (universally available via `pkg-config`).
- No changes to the Dart API layer.

---

## 2. Audio Library: miniaudio

**Choice:** [miniaudio](https://miniaud.io) v0.11.21 — single-header C library, vendored at `linux/third_party/miniaudio.h`.

**Why:**
- Zero system package dependencies for audio output; miniaudio dlopen()s PipeWire, PulseAudio, or ALSA at runtime in preference order.
- Built-in decoders (dr_wav, dr_mp3, dr_flac, stb_vorbis) cover WAV, MP3, FLAC, OGG — same format support as MediaFoundation on Windows.
- Pull/callback model maps cleanly to the 4-mode loop architecture.
- `notificationCallback` + `ma_device_notification_type_rerouted` available since v0.11.0.
- MIT licence; single file to vendor.

**Activation:** One dedicated TU (`miniaudio_impl.cpp`) defines `MINIAUDIO_IMPLEMENTATION` before the include. All other TUs include `miniaudio.h` without the define to get declarations only.

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
├── miniaudio_impl.cpp                    # #define MINIAUDIO_IMPLEMENTATION + include
└── third_party/
    └── miniaudio.h                       # Vendored v0.11.21 single-header
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
  miniaudio_impl.cpp        # exactly one TU defines MINIAUDIO_IMPLEMENTATION
)

apply_standard_settings(${PLUGIN_NAME})

target_include_directories(${PLUGIN_NAME} PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/third_party"
  ${CURL_INCLUDE_DIRS}
)

target_link_libraries(${PLUGIN_NAME} PUBLIC
  flutter_linux       # GLib-based Flutter Linux embedding (NOT "flutter")
  PkgConfig::CURL
  dl                  # miniaudio dlopen()s audio backends at runtime
  pthread             # std::thread, std::mutex
  m                   # math functions used by miniaudio
)

target_compile_definitions(${PLUGIN_NAME} PRIVATE
  FLUTTER_PLUGIN_IMPL
)
```

`apply_standard_settings` is a macro injected by Flutter's CMake toolchain (`flutter/ephemeral/cmake/flutter_linux.cmake`) that sets `CXX_VISIBILITY_PRESET hidden`, warning flags, and position-independent code. It must be called after `add_library`.

---

## 5. Core Engine (`loop_audio_engine`)

### 5.1 miniaudio Device

One `ma_device` per `LoopAudioEngine` instance. Configured as output-only, float32, matching the decoded channel count and sample rate:

```cpp
ma_device_config cfg = ma_device_config_init(ma_device_type_playback);
cfg.playback.format      = ma_format_f32;
cfg.playback.channels    = channelCount_;
cfg.sampleRate           = sampleRate_;
cfg.dataCallback         = DataCallback;
cfg.notificationCallback = NotificationCallback;
cfg.pUserData            = this;
ma_device_init(nullptr, &cfg, &device_);
```

### 5.2 Data Callback (loop logic)

All four playback modes are implemented inside the callback by advancing `readPos_` (a `double` for sub-frame accuracy when rate ≠ 1.0):

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

Linear interpolation between adjacent samples handles fractional `readPos_` (non-unity rate). All reads from shared state (`readPos_`, `loopStartFrame_`, `loopEndFrame_`, `playing_`) are done without locking — the callback owns these fields while the device is running; mutations from the main thread stop the device first.

### 5.3 Playback Rate

`readPos_` advances by `rate_` per output frame. At `rate_ = 1.0` this is sample-accurate. At other values, linear interpolation produces a speed and pitch change — matching Windows `SetFrequencyRatio` behaviour.

### 5.4 Amplitude Metering

RMS and peak are accumulated inside the callback. A `std::atomic<uint64_t>` frame counter gates emission to ~20 Hz. When the threshold is reached, a snapshot of rms/peak is posted via `PostToMainThread` (see Section 8.4). No separate polling thread needed.

### 5.5 Device Change (Reroute)

`NotificationCallback` fires on the miniaudio internal thread. **It must not call `ma_device_uninit` or `ma_device_stop` inline** — doing so deadlocks because miniaudio's uninit waits for the internal thread to exit (the thread that is currently executing the callback).

Correct pattern:
```cpp
static void NotificationCallback(const ma_device_notification* n) {
    auto* self = static_cast<LoopAudioEngine*>(n->pDevice->pUserData);
    if (n->type == ma_device_notification_type_rerouted) {
        self->PostToMainThread([self] {
            // safe to call ma_device_stop / ma_device_uninit / ma_device_init here
            self->HandleReroute();
        });
    }
}
```

`HandleReroute()` on the main thread: stop → uninit → reinit with same config → restart if was playing → emit `routeChange` event.

### 5.6 State Machine

Identical to Windows: `EngineState` enum (idle, loading, ready, playing, paused, stopped, error). `std::mutex stateMutex_` protects all public methods. The data callback does not lock — it reads fields that are only mutated when the device is stopped.

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

Implementation:
1. `ma_decoder_init_file` with `ma_format_f32` output config.
2. `ma_decoder_get_length_in_pcm_frames` to pre-allocate. **If it returns 0** (VBR MP3, some OGG files — length not known without full decode), fall back to a chunked-read loop: read fixed-size blocks (~65536 frames), append to the vector, stop when `framesRead < blockSize`.
3. `ma_decoder_uninit`.

### 6.2 URL Download

```cpp
static bool DecodeUrl(const std::string& url, DecodedAudio& out);
```

Uses `libcurl` in easy/synchronous mode:
1. Generate UUID temp path under `/tmp/fgl_<uuid>.<ext>`.
2. `curl_easy_setopt(CURLOPT_URL, ...)` + `CURLOPT_WRITEDATA` to file handle.
3. `curl_easy_perform`.
4. On success: `Decode(tempPath, out)`. Always `unlink(tempPath)` in cleanup (RAII wrapper or `defer`-equivalent).

### 6.3 Micro-Fade

5 ms linear ramp applied in-place at both ends of `pcm` after decode. Identical math to Windows `ApplyMicroFade`.

---

## 7. Metronome Engine (`metronome_engine`)

A second, independent `ma_device` instance per `MetronomeEngine`. The bar buffer (accent + clicks + silence) is pre-generated identically to Windows and Android: `buildBarBuffer(bpm, beatsPerBar, clickPcm, accentPcm)`. The callback reads cyclically: `readPos_ % barFrames_`.

**`SetBpm` / `SetBeatsPerBar` (bar buffer rebuild):**
Rebuilding the bar buffer while the audio callback is reading it is a data race. Safe sequence:
1. `ma_device_stop(&device_)` — blocks until the callback thread exits.
2. Rebuild `barBuffer_`, reset `readPos_` to 0, update `barFrames_`.
3. `ma_device_start(&device_)` — restart playback from beat 0.

Both calls are no-ops if the device has not been started (not yet started guard).

**Beat tick timer:** `std::thread` + `std::chrono::steady_clock`, same as Windows. Tick fires `PostToMainThread` with beat index.

**`SetVolume` / `SetPan`:** Gains are applied **live in the callback** (not baked into the bar buffer). `volume_`, `panLeft_`, and `panRight_` are `std::atomic<float>` so they can be written from the main thread and read from the callback thread without stopping the device. The callback multiplies each output frame's left/right channels by `volume_ * panLeft_` and `volume_ * panRight_` respectively.

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

The `_FlutterGaplessLoopPlugin` GObject struct contains a pointer to a C++ `PluginHandler` object that owns the engine maps and channel handles. The GObject `dispose` vfunc deletes the `PluginHandler`.

### 8.2 Channels

Four channels registered via `fl_method_channel_new` / `fl_event_channel_new`:

| Channel | Type |
|---------|------|
| `flutter_gapless_loop` | `FlMethodChannel` |
| `flutter_gapless_loop/events` | `FlEventChannel` |
| `flutter_gapless_loop/metronome` | `FlMethodChannel` |
| `flutter_gapless_loop/metronome/events` | `FlEventChannel` |

### 8.3 Event Channel Lifecycle

The Linux embedding has no `FlEventSink` type. Events are sent via:

```cpp
fl_event_channel_send(eventChannel_, value, nullptr, nullptr);
```

The `FlEventChannel` listen/cancel callbacks are set via `fl_event_channel_set_stream_handlers`. The C++ handler stores:
- `FlEventChannel* eventChannel_` — kept for the lifetime of the plugin.
- `bool eventChannelListening_` — set true in the listen callback, false in cancel.
- `bool metroChannelListening_` — same for metronome channel.

Events are only sent when the corresponding `*Listening_` flag is true.

### 8.4 Main-Thread Marshalling

Replaces Windows `PostMessage` + window proc delegate. GLib's `g_idle_add` posts work to the GLib main loop (Flutter's main thread):

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

**Cancellation on destroy — per-engine `alive_` sentinels:**

Each `LoopAudioEngine` and `MetronomeEngine` owns a `std::shared_ptr<std::atomic<bool>> alive_` initialised to `true`. Engine callbacks (state change, BPM, amplitude, beat tick, reroute) capture a copy of the engine's own `alive_` and a raw `self` pointer:

```cpp
auto alive = alive_;   // copy shared_ptr into lambda
auto* self = this;
PostToMainThread([self, alive, /* captured data */] {
    if (!*alive) return;   // engine already destroyed — discard
    // safe to use self and self->eventChannel_ here
});
```

**Destruction sequence (called from `PluginHandler` on `dispose`/`clearAll`):**
1. `*alive_ = false` — all subsequent idle callbacks become no-ops.
2. Stop and uninit the `ma_device` (joins the audio thread — no more callbacks fire after this).
3. `engines_.erase(pid)` / `metronomes_.erase(pid)` — `unique_ptr` destructor runs.

Because step 1 happens before step 3, any idle source already queued but not yet dispatched will see `!*alive` and return immediately without touching freed memory. Because GLib's main loop and the `PluginHandler` destructor both run on the same thread, no concurrent access is possible at the `PluginHandler` level.

### 8.5 Engine Registry and Method Handlers

The `PluginHandler` holds:

```cpp
std::map<std::string, std::unique_ptr<LoopAudioEngine>>  engines_;
std::map<std::string, std::unique_ptr<MetronomeEngine>>  metronomes_;
```

All method names, argument keys, and return types are identical to Windows. `clearAll` is handled before the `playerId` guard (same as all other platforms — required for hot-restart correctness).

### 8.6 Asset Path Resolution

```cpp
std::string GetAssetPath(const std::string& assetKey) {
    char exePath[PATH_MAX];
    ssize_t len = readlink("/proc/self/exe", exePath, sizeof(exePath) - 1);
    if (len <= 0) return "";           // guard: readlink failure
    exePath[len] = '\0';
    std::string exe(exePath);
    auto sep = exe.rfind('/');
    if (sep == std::string::npos) return "";   // guard: no separator
    return exe.substr(0, sep) + "/data/flutter_assets/" + assetKey;
}
```

Direct parallel to Windows `GetModuleFileNameW` approach.

### 8.7 Event Encoding

`FlValue` (GLib-based) is used in place of Windows `EncodableMap`. A helper constructs an `fl_value_new_map()` and populates it with string keys and typed values. Event structure (keys: `type`, `state`, `playerId`, `bpm`, `rms`, `peak`, `beat`, etc.) is identical to all other platforms.

---

## 9. pubspec.yaml & README Changes

**`pubspec.yaml`** — add to `flutter.plugin.platforms`:
```yaml
linux:
  pluginClass: FlutterGaplessLoopPlugin
```
Bump version to **`0.0.9`** (Linux support is a meaningful new platform addition; `0.0.8` is already used).

**`CHANGELOG.md`** — add `## 0.0.9` section:
```
### New platforms
* **Linux support.** Full implementation using miniaudio v0.11.21
  (PipeWire/PulseAudio/ALSA auto-selected at runtime) + libcurl for URL loading.
  Minimum: Ubuntu 20.04+ / glibc 2.31+.
```

**`README.md`** — add Linux row to platform table:
```
| Linux    | ✅  | miniaudio 0.11.21 (PipeWire / PulseAudio / ALSA) + libcurl (Ubuntu 20.04+) |
```

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
| miniaudio | v0.11.21 (vendored) |
| libcurl | any recent version (pkg-config) |
| Linux distro | Ubuntu 20.04+ (glibc 2.31+) |
| Audio backend | PipeWire, PulseAudio, or ALSA (miniaudio auto-selects via dlopen) |
