package com.fluttergaplessloop

import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Flutter plugin entry point for flutter_gapless_loop (Android).
 *
 * Registers:
 * - MethodChannel `"flutter_gapless_loop"` — handles all Dart API calls
 * - EventChannel  `"flutter_gapless_loop/events"` — pushes state changes to Dart
 *
 * Mirrors the iOS FlutterGaplessLoopPlugin in channel names, method names, and
 * event payload shapes so the shared Dart [LoopAudioPlayer] class works on both platforms.
 *
 * Threading contract:
 * - [onMethodCall] is called on the platform (main) thread by Flutter.
 * - [LoopAudioEngine.loadFile] suspends on IO; result is returned on Main.
 * - All [EventChannel.EventSink] calls are dispatched through [mainHandler] to satisfy
 *   Flutter's requirement that EventSink is only called from the platform thread.
 */
class FlutterGaplessLoopPlugin : FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        private const val TAG                   = "FlutterGaplessLoopPlugin"
        private const val METHOD_CHANNEL        = "flutter_gapless_loop"
        private const val EVENT_CHANNEL         = "flutter_gapless_loop/events"
        private const val METRO_METHOD_CHANNEL  = "flutter_gapless_loop/metronome"
        private const val METRO_EVENT_CHANNEL   = "flutter_gapless_loop/metronome/events"
    }

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel

    // Metronome channels
    private lateinit var metronomeMethodChannel: MethodChannel
    private lateinit var metronomeEventChannel: EventChannel

    /** EventSink for pushing state/error/route events to Dart. Null when not subscribed. */
    private var eventSink: EventChannel.EventSink? = null

    /** EventSink for pushing beat-tick events to Dart. Null when not subscribed. */
    private var metronomeEventSink: EventChannel.EventSink? = null

    private var engine: LoopAudioEngine? = null
    private var metronomeEngine: MetronomeEngine? = null
    private var pluginBinding: FlutterPlugin.FlutterPluginBinding? = null

    /** Coroutine scope for async operations (file loading). Main dispatcher = Flutter-safe. */
    private val pluginScope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    /** Ensures EventSink calls are always posted to the platform (main) thread. */
    private val mainHandler = Handler(Looper.getMainLooper())

    // ─── FlutterPlugin lifecycle ──────────────────────────────────────────────

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        pluginBinding = binding

        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL)
        methodChannel.setMethodCallHandler(this)

        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL)
        eventChannel.setStreamHandler(this)

        // Metronome channels — separate handler avoids method-name collisions with loop player
        metronomeMethodChannel = MethodChannel(binding.binaryMessenger, METRO_METHOD_CHANNEL)
        metronomeMethodChannel.setMethodCallHandler { call, result -> handleMetronomeCall(call, result) }

        metronomeEventChannel = EventChannel(binding.binaryMessenger, METRO_EVENT_CHANNEL)
        metronomeEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                metronomeEventSink = events
            }
            override fun onCancel(arguments: Any?) {
                metronomeEventSink = null
            }
        })

        Log.i(TAG, "Attached to engine")
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        metronomeMethodChannel.setMethodCallHandler(null)
        metronomeEventChannel.setStreamHandler(null)
        engine?.dispose()
        engine = null
        metronomeEngine?.dispose()
        metronomeEngine = null
        pluginBinding = null
        Log.i(TAG, "Detached from engine")
    }

    // ─── EventChannel.StreamHandler ──────────────────────────────────────────

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        // Lazily create the engine when Dart subscribes (matches iOS onListen behavior)
        getOrCreateEngine()
        Log.i(TAG, "Event channel opened")
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
        Log.i(TAG, "Event channel closed")
    }

    // ─── MethodChannel.MethodCallHandler ─────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: Result) {
        val eng = try {
            getOrCreateEngine()
        } catch (e: IllegalStateException) {
            return result.error("NOT_ATTACHED", e.message, null)
        }

        when (call.method) {

            // ── Load from absolute file path ──────────────────────────────────
            "load" -> {
                val path = call.argument<String>("path")
                    ?: return result.error("INVALID_ARGS", "'path' is required", null)
                pluginScope.launch {
                    try {
                        eng.loadFile(path)
                        result.success(null)
                    } catch (e: LoopAudioException) {
                        result.error("LOAD_FAILED", e.message, null)
                    } catch (e: Exception) {
                        result.error("LOAD_FAILED", e.message, null)
                    }
                }
            }

            // ── Load from Flutter asset key ───────────────────────────────────
            "loadAsset" -> {
                val assetKey = call.argument<String>("assetKey")
                    ?: return result.error("INVALID_ARGS", "'assetKey' is required", null)
                val binding = pluginBinding
                    ?: return result.error("REGISTRAR_MISSING", "Plugin not attached", null)

                // Resolve Flutter asset key (e.g. "assets/loop.wav") → relative APK assets path.
                // getAssetFilePathBySubpath handles full subpath keys, including subdirectories,
                // unlike getAssetFilePathByName which only matches by filename.
                val assetPath = binding.flutterAssets.getAssetFilePathBySubpath(assetKey)
                    ?: return result.error("ASSET_NOT_FOUND", "Asset not found: $assetKey", null)

                // Open asset as AssetFileDescriptor — works for assets inside the APK
                val assetFd = try {
                    binding.applicationContext.assets.openFd(assetPath)
                } catch (e: Exception) {
                    return result.error("ASSET_NOT_FOUND", "Cannot open asset: $assetKey — ${e.message}", null)
                }

                pluginScope.launch {
                    try {
                        eng.loadAsset(assetKey, assetFd)
                        result.success(null)
                    } catch (e: LoopAudioException) {
                        result.error("LOAD_FAILED", e.message, null)
                    } catch (e: Exception) {
                        result.error("LOAD_FAILED", e.message, null)
                    } finally {
                        try { assetFd.close() } catch (_: Exception) {}
                    }
                }
            }

            // ── Load from HTTP/HTTPS URL ──────────────────────────────────────
            "loadUrl" -> {
                val urlString = call.argument<String>("url")
                    ?: return result.error("INVALID_ARGS", "'url' is required", null)
                val uri = try { java.net.URI(urlString) } catch (_: Exception) { null }
                val scheme = uri?.scheme?.lowercase()
                if (scheme != "http" && scheme != "https") {
                    return result.error("INVALID_ARGS", "URL must use http or https scheme: $urlString", null)
                }
                val cacheDir = pluginBinding?.applicationContext?.cacheDir
                    ?: return result.error("NOT_ATTACHED", "Plugin not attached", null)
                pluginScope.launch {
                    var tempFile: java.io.File? = null
                    try {
                        tempFile = withContext(Dispatchers.IO) {
                            val ext = uri!!.path.substringAfterLast('.', "wav").take(10).ifEmpty { "wav" }
                            val tmp = java.io.File(
                                cacheDir,
                                "flutter_gapless_${java.util.UUID.randomUUID()}.$ext"
                            )
                            val conn = java.net.URL(urlString).openConnection() as java.net.HttpURLConnection
                            try {
                                conn.connectTimeout = 15_000
                                conn.readTimeout    = 30_000
                                conn.connect()
                                val status = conn.responseCode
                                if (status !in 200..299) {
                                    throw LoopAudioException(LoopEngineError.DecodeFailed("HTTP $status: $urlString"))
                                }
                                conn.inputStream.use { input ->
                                    tmp.outputStream().use { output -> input.copyTo(output) }
                                }
                                tmp
                            } finally {
                                conn.disconnect()
                            }
                        }
                        eng.loadFile(tempFile.absolutePath)
                        result.success(null)
                    } catch (e: LoopAudioException) {
                        Log.e(TAG, "loadUrl failed: ${e.message}")
                        result.error("LOAD_FAILED", e.message, null)
                    } catch (e: Exception) {
                        Log.e(TAG, "loadUrl failed: ${e.message}")
                        result.error("LOAD_FAILED", e.message, null)
                    } finally {
                        tempFile?.delete()
                    }
                }
            }

            "play"   -> { eng.play();   result.success(null) }
            "pause"  -> { eng.pause();  result.success(null) }
            "stop"   -> { eng.stop();   result.success(null) }
            "resume" -> { eng.resume(); result.success(null) }

            "setLoopRegion" -> {
                val start = call.argument<Double>("start") ?: 0.0
                val end   = call.argument<Double>("end")   ?: 0.0
                eng.setLoopRegion(start, end)
                result.success(null)
            }

            "setCrossfadeDuration" -> {
                val duration = call.argument<Double>("duration") ?: 0.0
                eng.setCrossfadeDuration(duration)
                result.success(null)
            }

            "setVolume" -> {
                val volume = call.argument<Double>("volume")?.toFloat() ?: 1.0f
                eng.setVolume(volume)
                result.success(null)
            }

            "setPan" -> {
                val pan = call.argument<Double>("pan")?.toFloat() ?: 0f
                eng.setPan(pan)
                result.success(null)
            }

            "setPlaybackRate" -> {
                val rate = call.argument<Double>("rate")?.toFloat() ?: 1f
                eng.setPlaybackRate(rate)
                result.success(null)
            }

            "seek" -> {
                val position = call.argument<Double>("position") ?: 0.0
                eng.seek(position)
                result.success(null)
            }

            "getDuration"         -> result.success(eng.duration)
            "getCurrentPosition"  -> result.success(eng.currentTime)

            "dispose" -> {
                eng.dispose()
                engine = null
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    // ─── Private helpers ──────────────────────────────────────────────────────

    /**
     * Returns the existing engine or creates a fresh one.
     *
     * Creating lazily (rather than in [onAttachedToEngine]) matches the iOS pattern
     * where the engine is built in [onListen], allowing hot-restart to work correctly.
     */
    private fun getOrCreateEngine(): LoopAudioEngine {
        return engine ?: run {
            val ctx = pluginBinding?.applicationContext
                ?: throw IllegalStateException("Plugin not attached to an engine")
            val eng = LoopAudioEngine(ctx)
            wireEngineCallbacks(eng)
            engine = eng
            eng
        }
    }

    /**
     * Connects [LoopAudioEngine] callbacks to [eventSink] so Dart receives events.
     *
     * Event payload shapes (must match iOS FlutterGaplessLoopPlugin.swift):
     * - State change: `{"type": "stateChange", "state": "playing"}`
     * - Error:        `{"type": "error", "message": "..."}`
     * - Route change: `{"type": "routeChange", "reason": "headphonesUnplugged"}`
     */
    private fun wireEngineCallbacks(eng: LoopAudioEngine) {
        eng.onStateChange = { state ->
            sendEvent(mapOf("type" to "stateChange", "state" to state.rawValue))
        }
        eng.onError = { error ->
            sendEvent(mapOf("type" to "error", "message" to error.toMessage()))
        }
        eng.onRouteChange = { reason ->
            sendEvent(mapOf("type" to "routeChange", "reason" to reason))
        }
        eng.onBpmDetected = { bpmResult ->
            sendEvent(mapOf(
                "type"        to "bpmDetected",
                "bpm"         to bpmResult.bpm,
                "confidence"  to bpmResult.confidence,
                "beats"       to bpmResult.beats,
                "beatsPerBar" to bpmResult.beatsPerBar,
                "bars"        to bpmResult.bars
            ))
        }
    }

    /**
     * Posts an event map to [eventSink] on the platform (main) thread.
     *
     * Flutter requires that [EventChannel.EventSink.success] is always called from
     * the platform thread. [mainHandler.post] guarantees this regardless of which
     * thread the engine callback fires on.
     */
    private fun sendEvent(event: Map<String, Any>) {
        mainHandler.post { eventSink?.success(event) }
    }

    // ─── Metronome ────────────────────────────────────────────────────────────

    private fun handleMetronomeCall(call: MethodCall, result: Result) {
        when (call.method) {

            "start" -> {
                val bpm         = call.argument<Double>("bpm")
                    ?: return result.error("INVALID_ARGS", "'bpm' required", null)
                val beatsPerBar = call.argument<Int>("beatsPerBar")
                    ?: return result.error("INVALID_ARGS", "'beatsPerBar' required", null)
                val clickBytes  = call.argument<ByteArray>("click")
                    ?: return result.error("INVALID_ARGS", "'click' required", null)
                val accentBytes = call.argument<ByteArray>("accent")
                    ?: return result.error("INVALID_ARGS", "'accent' required", null)
                val ext         = call.argument<String>("extension") ?: "wav"

                getOrCreateMetronomeEngine().start(bpm, beatsPerBar, clickBytes, accentBytes, ext)
                result.success(null)
            }

            "setBpm" -> {
                val bpm = call.argument<Double>("bpm")
                    ?: return result.error("INVALID_ARGS", "'bpm' required", null)
                metronomeEngine?.setBpm(bpm)
                result.success(null)
            }

            "setBeatsPerBar" -> {
                val beatsPerBar = call.argument<Int>("beatsPerBar")
                    ?: return result.error("INVALID_ARGS", "'beatsPerBar' required", null)
                metronomeEngine?.setBeatsPerBar(beatsPerBar)
                result.success(null)
            }

            "stop" -> {
                metronomeEngine?.stop()
                result.success(null)
            }

            "dispose" -> {
                metronomeEngine?.dispose()
                metronomeEngine = null
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    private fun getOrCreateMetronomeEngine(): MetronomeEngine {
        metronomeEngine?.let { return it }
        val eng = MetronomeEngine(
            onBeatTick = { beat ->
                mainHandler.post {
                    metronomeEventSink?.success(mapOf("type" to "beatTick", "beat" to beat))
                }
            },
            onError = { msg ->
                mainHandler.post {
                    metronomeEventSink?.success(mapOf("type" to "error", "message" to msg))
                }
            }
        )
        metronomeEngine = eng
        return eng
    }
}
