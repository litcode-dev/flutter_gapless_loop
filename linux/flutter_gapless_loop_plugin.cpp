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
            // Build beat/bar lists on calling thread, then marshal to main.
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
