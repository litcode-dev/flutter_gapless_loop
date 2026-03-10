#include "include/flutter_gapless_loop/flutter_gapless_loop_plugin.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include "loop_audio_engine.h"
#include "metronome_engine.h"

#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <queue>
#include <string>

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using MethodResult = flutter::MethodResult<EncodableValue>;
using MethodCall   = flutter::MethodCall<EncodableValue>;

// ─── Argument helpers ─────────────────────────────────────────────────────────

static const EncodableMap* ArgsMap(const MethodCall& call) {
    return std::get_if<EncodableMap>(&call.arguments());
}

static const EncodableValue* Arg(const EncodableMap* m, const char* key) {
    if (!m) return nullptr;
    auto it = m->find(EncodableValue(key));
    return (it != m->end()) ? &it->second : nullptr;
}

static std::optional<std::string> ArgStr(const EncodableMap* m, const char* key) {
    auto* v = Arg(m, key);
    if (!v) return std::nullopt;
    if (auto* s = std::get_if<std::string>(v)) return *s;
    return std::nullopt;
}

static std::optional<double> ArgDouble(const EncodableMap* m, const char* key) {
    auto* v = Arg(m, key);
    if (!v) return std::nullopt;
    if (auto* d  = std::get_if<double>  (v)) return *d;
    if (auto* i32 = std::get_if<int32_t>(v)) return *i32;
    if (auto* i64 = std::get_if<int64_t>(v)) return static_cast<double>(*i64);
    return std::nullopt;
}

static std::optional<int64_t> ArgInt(const EncodableMap* m, const char* key) {
    auto* v = Arg(m, key);
    if (!v) return std::nullopt;
    if (auto* i32 = std::get_if<int32_t>(v)) return *i32;
    if (auto* i64 = std::get_if<int64_t>(v)) return *i64;
    return std::nullopt;
}

static const std::vector<uint8_t>* ArgBytes(const EncodableMap* m, const char* key) {
    auto* v = Arg(m, key);
    if (!v) return nullptr;
    return std::get_if<std::vector<uint8_t>>(v);
}

// ─── FlutterGaplessLoopPlugin ─────────────────────────────────────────────────

class FlutterGaplessLoopPlugin : public flutter::Plugin {
public:
    static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

    explicit FlutterGaplessLoopPlugin(flutter::PluginRegistrarWindows* registrar);
    ~FlutterGaplessLoopPlugin() override;

private:
    static constexpr UINT kDrainMsg = WM_APP + 0x676C;  // "gl"

    flutter::PluginRegistrarWindows* registrar_;
    HWND   hwnd_          = nullptr;
    int    winProcId_     = -1;

    // Event sinks — written from main thread only, read from engine callbacks.
    std::unique_ptr<flutter::EventSink<EncodableValue>> loopEventSink_;
    std::unique_ptr<flutter::EventSink<EncodableValue>> metroEventSink_;

    // Engine registries (keyed by playerId).
    std::map<std::string, std::unique_ptr<LoopAudioEngine>>  engines_;
    std::map<std::string, std::unique_ptr<MetronomeEngine>>  metronomes_;

    // Main-thread callback queue.
    std::mutex                       cbMutex_;
    std::queue<std::function<void()>> callbacks_;

    // Post a callback to be executed on the Flutter platform thread.
    void PostCb(std::function<void()> fn) {
        { std::lock_guard<std::mutex> g(cbMutex_); callbacks_.push(std::move(fn)); }
        if (hwnd_) PostMessage(hwnd_, kDrainMsg, 0, 0);
    }

    void DrainCallbacks() {
        std::queue<std::function<void()>> q;
        { std::lock_guard<std::mutex> g(cbMutex_); std::swap(q, callbacks_); }
        while (!q.empty()) { q.front()(); q.pop(); }
    }

    // Engine helpers.
    LoopAudioEngine*  GetOrCreateEngine  (const std::string& pid);
    MetronomeEngine*  GetOrCreateMetronome(const std::string& pid);
    void              WireEngineCallbacks(LoopAudioEngine* eng, const std::string& pid);

    // Channel handlers.
    void HandleLoopCall(const MethodCall& call,
                        std::unique_ptr<MethodResult> result);
    void HandleMetronomeCall(const MethodCall& call,
                             std::unique_ptr<MethodResult> result);
};

// ─── Registration ─────────────────────────────────────────────────────────────

void FlutterGaplessLoopPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar)
{
    auto plugin = std::make_unique<FlutterGaplessLoopPlugin>(registrar);

    // Loop player channels.
    auto loopMethod = std::make_unique<flutter::MethodChannel<EncodableValue>>(
        registrar->messenger(), "flutter_gapless_loop",
        &flutter::StandardMethodCodec::GetInstance());

    loopMethod->SetMethodCallHandler(
        [p = plugin.get()](const MethodCall& call,
                           std::unique_ptr<MethodResult> result) {
            p->HandleLoopCall(call, std::move(result));
        });

    auto loopEvent = std::make_unique<flutter::EventChannel<EncodableValue>>(
        registrar->messenger(), "flutter_gapless_loop/events",
        &flutter::StandardMethodCodec::GetInstance());
    loopEvent->SetStreamHandler(
        std::make_unique<flutter::StreamHandlerFunctions<EncodableValue>>(
            [p = plugin.get()](const EncodableValue*,
                               std::unique_ptr<flutter::EventSink<EncodableValue>>&& sink)
                -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
                p->loopEventSink_ = std::move(sink);
                return nullptr;
            },
            [p = plugin.get()](const EncodableValue*)
                -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
                p->loopEventSink_.reset();
                return nullptr;
            }));

    // Metronome channels.
    auto metroMethod = std::make_unique<flutter::MethodChannel<EncodableValue>>(
        registrar->messenger(), "flutter_gapless_loop/metronome",
        &flutter::StandardMethodCodec::GetInstance());
    metroMethod->SetMethodCallHandler(
        [p = plugin.get()](const MethodCall& call,
                           std::unique_ptr<MethodResult> result) {
            p->HandleMetronomeCall(call, std::move(result));
        });

    auto metroEvent = std::make_unique<flutter::EventChannel<EncodableValue>>(
        registrar->messenger(), "flutter_gapless_loop/metronome/events",
        &flutter::StandardMethodCodec::GetInstance());
    metroEvent->SetStreamHandler(
        std::make_unique<flutter::StreamHandlerFunctions<EncodableValue>>(
            [p = plugin.get()](const EncodableValue*,
                               std::unique_ptr<flutter::EventSink<EncodableValue>>&& sink)
                -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
                p->metroEventSink_ = std::move(sink);
                return nullptr;
            },
            [p = plugin.get()](const EncodableValue*)
                -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
                p->metroEventSink_.reset();
                return nullptr;
            }));

    registrar->AddPlugin(std::move(plugin));
}

FlutterGaplessLoopPlugin::FlutterGaplessLoopPlugin(
    flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar)
{
    hwnd_ = registrar->GetView()
                ? reinterpret_cast<HWND>(registrar->GetView()->GetNativeWindow())
                : nullptr;

    if (hwnd_) {
        winProcId_ = registrar->RegisterTopLevelWindowProcDelegate(
            [this](HWND, UINT msg, WPARAM, LPARAM) -> std::optional<LRESULT> {
                if (msg == kDrainMsg) { DrainCallbacks(); return 0; }
                return std::nullopt;
            });
    }
}

FlutterGaplessLoopPlugin::~FlutterGaplessLoopPlugin() {
    if (winProcId_ >= 0)
        registrar_->UnregisterTopLevelWindowProcDelegate(winProcId_);
    engines_.clear();
    metronomes_.clear();
}

// ─── Engine Registry ──────────────────────────────────────────────────────────

LoopAudioEngine* FlutterGaplessLoopPlugin::GetOrCreateEngine(const std::string& pid) {
    auto it = engines_.find(pid);
    if (it != engines_.end()) return it->second.get();
    auto eng = std::make_unique<LoopAudioEngine>();
    auto* raw = eng.get();
    WireEngineCallbacks(raw, pid);
    engines_[pid] = std::move(eng);
    return raw;
}

void FlutterGaplessLoopPlugin::WireEngineCallbacks(
    LoopAudioEngine* eng, const std::string& pid)
{
    eng->onStateChange = [this, pid](EngineState s) {
        PostCb([this, pid, s]() {
            if (!loopEventSink_) return;
            loopEventSink_->Success(EncodableValue(EncodableMap{
                {EncodableValue("playerId"), EncodableValue(pid)},
                {EncodableValue("type"),     EncodableValue("stateChange")},
                {EncodableValue("state"),    EncodableValue(std::string(EngineStateStr(s)))},
            }));
        });
    };

    eng->onError = [this, pid](std::string msg) {
        PostCb([this, pid, msg]() {
            if (!loopEventSink_) return;
            loopEventSink_->Success(EncodableValue(EncodableMap{
                {EncodableValue("playerId"), EncodableValue(pid)},
                {EncodableValue("type"),     EncodableValue("error")},
                {EncodableValue("message"),  EncodableValue(msg)},
            }));
        });
    };

    eng->onRouteChange = [this, pid](std::string reason) {
        PostCb([this, pid, reason]() {
            if (!loopEventSink_) return;
            loopEventSink_->Success(EncodableValue(EncodableMap{
                {EncodableValue("playerId"), EncodableValue(pid)},
                {EncodableValue("type"),     EncodableValue("routeChange")},
                {EncodableValue("reason"),   EncodableValue(reason)},
            }));
        });
    };

    eng->onBpmDetected = [this, pid](BpmResult r) {
        // Convert beats/bars vectors.
        EncodableList beats, bars;
        beats.reserve(r.beats.size());
        for (double b : r.beats) beats.push_back(EncodableValue(b));
        bars.reserve(r.bars.size());
        for (double b : r.bars) bars.push_back(EncodableValue(b));

        PostCb([this, pid, r, beats = std::move(beats), bars = std::move(bars)]() mutable {
            if (!loopEventSink_) return;
            loopEventSink_->Success(EncodableValue(EncodableMap{
                {EncodableValue("playerId"),    EncodableValue(pid)},
                {EncodableValue("type"),        EncodableValue("bpmDetected")},
                {EncodableValue("bpm"),         EncodableValue(r.bpm)},
                {EncodableValue("confidence"),  EncodableValue(r.confidence)},
                {EncodableValue("beats"),       EncodableValue(std::move(beats))},
                {EncodableValue("beatsPerBar"), EncodableValue(static_cast<int32_t>(r.beatsPerBar))},
                {EncodableValue("bars"),        EncodableValue(std::move(bars))},
            }));
        });
    };

    eng->onAmplitude = [this, pid](float rms, float peak) {
        PostCb([this, pid, rms, peak]() {
            if (!loopEventSink_) return;
            loopEventSink_->Success(EncodableValue(EncodableMap{
                {EncodableValue("playerId"), EncodableValue(pid)},
                {EncodableValue("type"),     EncodableValue("amplitude")},
                {EncodableValue("rms"),      EncodableValue(static_cast<double>(rms))},
                {EncodableValue("peak"),     EncodableValue(static_cast<double>(peak))},
            }));
        });
    };
}

MetronomeEngine* FlutterGaplessLoopPlugin::GetOrCreateMetronome(const std::string& pid) {
    auto it = metronomes_.find(pid);
    if (it != metronomes_.end()) return it->second.get();

    auto eng = std::make_unique<MetronomeEngine>();
    auto* raw = eng.get();

    raw->onBeatTick = [this, pid](int beat) {
        PostCb([this, pid, beat]() {
            if (!metroEventSink_) return;
            metroEventSink_->Success(EncodableValue(EncodableMap{
                {EncodableValue("playerId"), EncodableValue(pid)},
                {EncodableValue("type"),     EncodableValue("beatTick")},
                {EncodableValue("beat"),     EncodableValue(beat)},
            }));
        });
    };
    raw->onError = [this, pid](std::string msg) {
        PostCb([this, pid, msg]() {
            if (!metroEventSink_) return;
            metroEventSink_->Success(EncodableValue(EncodableMap{
                {EncodableValue("playerId"), EncodableValue(pid)},
                {EncodableValue("type"),     EncodableValue("error")},
                {EncodableValue("message"),  EncodableValue(msg)},
            }));
        });
    };

    metronomes_[pid] = std::move(eng);
    return raw;
}

// ─── Loop Player Method Handler ───────────────────────────────────────────────

void FlutterGaplessLoopPlugin::HandleLoopCall(
    const MethodCall& call, std::unique_ptr<MethodResult> result)
{
    const auto* args = ArgsMap(call);
    const auto  pid  = ArgStr(args, "playerId");
    if (!pid) {
        result->Error("INVALID_ARGS", "'playerId' is required");
        return;
    }

    auto* eng = GetOrCreateEngine(*pid);

    if (call.method_name() == "load") {
        auto path = ArgStr(args, "path");
        if (!path) { result->Error("INVALID_ARGS", "'path' is required"); return; }
        std::wstring wpath(path->begin(), path->end());
        if (!eng->LoadFile(wpath))
            result->Error("LOAD_FAILED", "Failed to load file");
        else
            result->Success();

    } else if (call.method_name() == "loadAsset") {
        auto assetKey = ArgStr(args, "assetKey");
        if (!assetKey) { result->Error("INVALID_ARGS", "'assetKey' is required"); return; }

        // Flutter assets on Windows: <exe_dir>/data/flutter_assets/<key>
        wchar_t exePath[MAX_PATH] = {};
        GetModuleFileNameW(nullptr, exePath, MAX_PATH);
        std::wstring exeDir(exePath);
        const auto lastSep = exeDir.rfind(L'\\');
        if (lastSep != std::wstring::npos) exeDir = exeDir.substr(0, lastSep);
        const std::wstring assetPath =
            exeDir + L"\\data\\flutter_assets\\" +
            std::wstring(assetKey->begin(), assetKey->end());

        if (!eng->LoadFile(assetPath))
            result->Error("LOAD_FAILED", "Asset not found or failed to decode");
        else
            result->Success();

    } else if (call.method_name() == "loadUrl") {
        auto url = ArgStr(args, "url");
        if (!url) { result->Error("INVALID_ARGS", "'url' is required"); return; }
        std::wstring wurl(url->begin(), url->end());
        // LoadUrl downloads synchronously; caller should invoke on background thread.
        if (!eng->LoadUrl(wurl))
            result->Error("LOAD_FAILED", "Failed to download or decode URL");
        else
            result->Success();

    } else if (call.method_name() == "play") {
        eng->Play();
        result->Success();

    } else if (call.method_name() == "pause") {
        eng->Pause();
        result->Success();

    } else if (call.method_name() == "resume") {
        eng->Resume();
        result->Success();

    } else if (call.method_name() == "stop") {
        eng->Stop();
        result->Success();

    } else if (call.method_name() == "setLoopRegion") {
        auto start = ArgDouble(args, "start");
        auto end   = ArgDouble(args, "end");
        if (!start || !end) {
            result->Error("INVALID_ARGS", "'start' and 'end' are required");
            return;
        }
        if (!eng->SetLoopRegion(*start, *end))
            result->Error("INVALID_REGION", "Loop region out of bounds or invalid");
        else
            result->Success();

    } else if (call.method_name() == "setCrossfadeDuration") {
        auto dur = ArgDouble(args, "duration");
        if (!dur) { result->Error("INVALID_ARGS", "'duration' is required"); return; }
        eng->SetCrossfadeDuration(*dur);
        result->Success();

    } else if (call.method_name() == "setVolume") {
        auto vol = ArgDouble(args, "volume");
        if (!vol) { result->Error("INVALID_ARGS", "'volume' is required"); return; }
        eng->SetVolume(static_cast<float>(*vol));
        result->Success();

    } else if (call.method_name() == "setPan") {
        auto pan = ArgDouble(args, "pan");
        if (!pan) { result->Error("INVALID_ARGS", "'pan' is required"); return; }
        eng->SetPan(static_cast<float>(*pan));
        result->Success();

    } else if (call.method_name() == "setPlaybackRate") {
        auto rate = ArgDouble(args, "rate");
        if (!rate) { result->Error("INVALID_ARGS", "'rate' is required"); return; }
        eng->SetPlaybackRate(static_cast<float>(*rate));
        result->Success();

    } else if (call.method_name() == "seek") {
        auto pos = ArgDouble(args, "position");
        if (!pos) { result->Error("INVALID_ARGS", "'position' is required"); return; }
        if (!eng->Seek(*pos))
            result->Error("SEEK_FAILED", "Position out of bounds");
        else
            result->Success();

    } else if (call.method_name() == "getDuration") {
        result->Success(EncodableValue(eng->GetDuration()));

    } else if (call.method_name() == "getCurrentPosition") {
        result->Success(EncodableValue(eng->GetCurrentPosition()));

    } else if (call.method_name() == "dispose") {
        eng->Dispose();
        engines_.erase(*pid);
        result->Success();

    } else {
        result->NotImplemented();
    }
}

// ─── Metronome Method Handler ─────────────────────────────────────────────────

void FlutterGaplessLoopPlugin::HandleMetronomeCall(
    const MethodCall& call, std::unique_ptr<MethodResult> result)
{
    const auto* args = ArgsMap(call);
    const auto  pid  = ArgStr(args, "playerId");
    if (!pid) {
        result->Error("INVALID_ARGS", "'playerId' is required");
        return;
    }

    if (call.method_name() == "start") {
        auto bpmVal    = ArgDouble(args, "bpm");
        auto beatsVal  = ArgInt   (args, "beatsPerBar");
        auto* click    = ArgBytes (args, "click");
        auto* accent   = ArgBytes (args, "accent");

        if (!bpmVal || !beatsVal || !click || !accent) {
            result->Error("INVALID_ARGS",
                          "start requires bpm, beatsPerBar, click, accent");
            return;
        }
        auto ext = ArgStr(args, "extension").value_or("wav");
        auto* eng = GetOrCreateMetronome(*pid);
        eng->Start(*bpmVal, static_cast<int>(*beatsVal),
                   *click, *accent, ext);
        result->Success();

    } else if (call.method_name() == "setBpm") {
        auto bpmVal = ArgDouble(args, "bpm");
        if (!bpmVal) { result->Error("INVALID_ARGS", "'bpm' required"); return; }
        auto it = metronomes_.find(*pid);
        if (it != metronomes_.end()) it->second->SetBpm(*bpmVal);
        result->Success();

    } else if (call.method_name() == "setBeatsPerBar") {
        auto beats = ArgInt(args, "beatsPerBar");
        if (!beats) { result->Error("INVALID_ARGS", "'beatsPerBar' required"); return; }
        auto it = metronomes_.find(*pid);
        if (it != metronomes_.end())
            it->second->SetBeatsPerBar(static_cast<int>(*beats));
        result->Success();

    } else if (call.method_name() == "setVolume") {
        auto vol = ArgDouble(args, "volume");
        if (!vol) { result->Error("INVALID_ARGS", "'volume' required"); return; }
        auto it = metronomes_.find(*pid);
        if (it != metronomes_.end()) it->second->SetVolume(static_cast<float>(*vol));
        result->Success();

    } else if (call.method_name() == "setPan") {
        auto pan = ArgDouble(args, "pan");
        if (!pan) { result->Error("INVALID_ARGS", "'pan' required"); return; }
        auto it = metronomes_.find(*pid);
        if (it != metronomes_.end()) it->second->SetPan(static_cast<float>(*pan));
        result->Success();

    } else if (call.method_name() == "stop") {
        auto it = metronomes_.find(*pid);
        if (it != metronomes_.end()) it->second->Stop();
        result->Success();

    } else if (call.method_name() == "dispose") {
        auto it = metronomes_.find(*pid);
        if (it != metronomes_.end()) { it->second->Dispose(); metronomes_.erase(it); }
        result->Success();

    } else {
        result->NotImplemented();
    }
}

// ─── C entry point ────────────────────────────────────────────────────────────

void FlutterGaplessLoopPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar)
{
    FlutterGaplessLoopPlugin::RegisterWithRegistrar(
        flutter::PluginRegistrarManager::GetInstance()
            ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
