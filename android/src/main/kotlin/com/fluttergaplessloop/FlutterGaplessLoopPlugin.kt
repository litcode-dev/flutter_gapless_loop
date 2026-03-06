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
 * Multiple concurrent players are supported: each Dart [LoopAudioPlayer] instance
 * includes a unique `playerId` in every method call, and all events are tagged with
 * the same `playerId` so the Dart layer can filter them without cross-talk.
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

    /** Registry of active loop engines keyed by player ID. */
    private val engines    = HashMap<String, LoopAudioEngine>()
    /** Registry of active metronome engines keyed by player ID. */
    private val metronomes = HashMap<String, MetronomeEngine>()

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
        engines.values.forEach { it.dispose() }
        engines.clear()
        metronomes.values.forEach { it.dispose() }
        metronomes.clear()
        pluginBinding = null
        Log.i(TAG, "Detached from engine")
    }

    // ─── EventChannel.StreamHandler ──────────────────────────────────────────

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        Log.i(TAG, "Event channel opened")
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
        Log.i(TAG, "Event channel closed")
    }

    // ─── MethodChannel.MethodCallHandler ─────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: Result) {
        val playerId = call.argument<String>("playerId")
            ?: return result.error("INVALID_ARGS", "'playerId' is required", null)

        val eng = try {
            getOrCreateEngine(playerId)
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

                val assetPath = binding.flutterAssets.getAssetFilePathBySubpath(assetKey)
                    ?: return result.error("ASSET_NOT_FOUND", "Asset not found: $assetKey", null)

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
                engines.remove(playerId)
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    // ─── Private helpers ──────────────────────────────────────────────────────

    /**
     * Returns the existing engine for [playerId], or creates a fresh one.
     *
     * Creating lazily (rather than in [onAttachedToEngine]) matches the iOS pattern
     * where the engine is built on first use, allowing hot-restart to work correctly.
     */
    private fun getOrCreateEngine(playerId: String): LoopAudioEngine {
        return engines.getOrPut(playerId) {
            val ctx = pluginBinding?.applicationContext
                ?: throw IllegalStateException("Plugin not attached to an engine")
            val eng = LoopAudioEngine(ctx)
            wireEngineCallbacks(eng, playerId)
            eng
        }
    }

    /**
     * Connects [LoopAudioEngine] callbacks to [eventSink], tagging each event with [playerId].
     *
     * Event payload shapes (must match iOS FlutterGaplessLoopPlugin.swift):
     * - State change: `{"playerId": "loop_0", "type": "stateChange", "state": "playing"}`
     * - Error:        `{"playerId": "loop_0", "type": "error", "message": "..."}`
     * - Route change: `{"playerId": "loop_0", "type": "routeChange", "reason": "headphonesUnplugged"}`
     */
    private fun wireEngineCallbacks(eng: LoopAudioEngine, playerId: String) {
        eng.onStateChange = { state ->
            sendEvent(mapOf("playerId" to playerId, "type" to "stateChange", "state" to state.rawValue))
        }
        eng.onError = { error ->
            sendEvent(mapOf("playerId" to playerId, "type" to "error", "message" to error.toMessage()))
        }
        eng.onRouteChange = { reason ->
            sendEvent(mapOf("playerId" to playerId, "type" to "routeChange", "reason" to reason))
        }
        eng.onBpmDetected = { bpmResult ->
            sendEvent(mapOf(
                "playerId"    to playerId,
                "type"        to "bpmDetected",
                "bpm"         to bpmResult.bpm,
                "confidence"  to bpmResult.confidence,
                "beats"       to bpmResult.beats,
                "beatsPerBar" to bpmResult.beatsPerBar,
                "bars"        to bpmResult.bars
            ))
        }
        eng.onAmplitude = { rms, peak ->
            sendEvent(mapOf(
                "playerId" to playerId,
                "type"     to "amplitude",
                "rms"      to rms,
                "peak"     to peak
            ))
        }
    }

    /**
     * Posts an event map to [eventSink] on the platform (main) thread.
     */
    private fun sendEvent(event: Map<String, Any>) {
        mainHandler.post { eventSink?.success(event) }
    }

    // ─── Metronome ────────────────────────────────────────────────────────────

    private fun handleMetronomeCall(call: MethodCall, result: Result) {
        val playerId = call.argument<String>("playerId")
            ?: return result.error("INVALID_ARGS", "'playerId' is required", null)

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

                getOrCreateMetronomeEngine(playerId).start(bpm, beatsPerBar, clickBytes, accentBytes, ext)
                result.success(null)
            }

            "setBpm" -> {
                val bpm = call.argument<Double>("bpm")
                    ?: return result.error("INVALID_ARGS", "'bpm' required", null)
                metronomes[playerId]?.setBpm(bpm)
                result.success(null)
            }

            "setBeatsPerBar" -> {
                val beatsPerBar = call.argument<Int>("beatsPerBar")
                    ?: return result.error("INVALID_ARGS", "'beatsPerBar' required", null)
                metronomes[playerId]?.setBeatsPerBar(beatsPerBar)
                result.success(null)
            }

            "setVolume" -> {
                val volume = call.argument<Double>("volume")?.toFloat()
                    ?: return result.error("INVALID_ARGS", "'volume' required", null)
                metronomes[playerId]?.setVolume(volume)
                result.success(null)
            }

            "setPan" -> {
                val pan = call.argument<Double>("pan")?.toFloat()
                    ?: return result.error("INVALID_ARGS", "'pan' required", null)
                metronomes[playerId]?.setPan(pan)
                result.success(null)
            }

            "stop" -> {
                metronomes[playerId]?.stop()
                result.success(null)
            }

            "dispose" -> {
                metronomes[playerId]?.dispose()
                metronomes.remove(playerId)
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    private fun getOrCreateMetronomeEngine(playerId: String): MetronomeEngine {
        return metronomes.getOrPut(playerId) {
            MetronomeEngine(
                onBeatTick = { beat ->
                    mainHandler.post {
                        metronomeEventSink?.success(
                            mapOf("playerId" to playerId, "type" to "beatTick", "beat" to beat))
                    }
                },
                onError = { msg ->
                    mainHandler.post {
                        metronomeEventSink?.success(
                            mapOf("playerId" to playerId, "type" to "error", "message" to msg))
                    }
                }
            )
        }
    }
}
