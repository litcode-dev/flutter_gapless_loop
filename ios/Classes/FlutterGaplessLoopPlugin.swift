#if os(iOS)
import Flutter
import UIKit
import AVFoundation
import os.log

// MARK: - MetronomeStreamHandler

/// Dedicated FlutterStreamHandler for the metronome event channel.
/// Kept separate from the loop-player handler to isolate lifecycle.
private final class MetronomeStreamHandler: NSObject, FlutterStreamHandler {
    var eventSink: FlutterEventSink?

    func onListen(withArguments arguments: Any?,
                  eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }
}

// MARK: - MetronomeMethodHandler

/// Routes method calls on "flutter_gapless_loop/metronome" to the plugin.
///
/// Using a separate delegate object prevents name collisions between
/// the metronome's "stop"/"dispose" and the loop player's identically-named methods.
private final class MetronomeMethodHandler: NSObject, FlutterPlugin {
    static func register(with registrar: FlutterPluginRegistrar) {}

    weak var plugin: FlutterGaplessLoopPlugin?

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        plugin?.handleMetronomeCall(call, result: result)
    }
}

// MARK: - FlutterGaplessLoopPlugin

/// The Flutter plugin entry point for flutter_gapless_loop.
///
/// Registers the method channel and event channel, instantiates [LoopAudioEngine],
/// and routes all Flutter method calls to the engine.
public class FlutterGaplessLoopPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

    // MARK: - Private Properties

    private var engine: LoopAudioEngine?
    private var eventSink: FlutterEventSink?
    private var registrar: FlutterPluginRegistrar?
    private let logger = Logger(subsystem: "com.fluttergaplessloop", category: "Plugin")

    // Metronome
    private var metronomeEngine: MetronomeEngine?
    private let metronomeStreamHandler = MetronomeStreamHandler()
    private let metronomeMethodHandler = MetronomeMethodHandler()

    // MARK: - FlutterPlugin Registration

    /// Registers the method channel and event channel with the Flutter plugin registrar.
    public static func register(with registrar: FlutterPluginRegistrar) {
        let methodChannel = FlutterMethodChannel(
            name: "flutter_gapless_loop",
            binaryMessenger: registrar.messenger()
        )
        let eventChannel = FlutterEventChannel(
            name: "flutter_gapless_loop/events",
            binaryMessenger: registrar.messenger()
        )

        let instance = FlutterGaplessLoopPlugin()
        instance.registrar = registrar
        registrar.addMethodCallDelegate(instance, channel: methodChannel)
        eventChannel.setStreamHandler(instance)

        // Metronome channels — separate handler to avoid method-name collisions
        let metronomeMethodChannel = FlutterMethodChannel(
            name: "flutter_gapless_loop/metronome",
            binaryMessenger: registrar.messenger()
        )
        let metronomeEventChannel = FlutterEventChannel(
            name: "flutter_gapless_loop/metronome/events",
            binaryMessenger: registrar.messenger()
        )
        instance.metronomeMethodHandler.plugin = instance
        registrar.addMethodCallDelegate(instance.metronomeMethodHandler,
                                        channel: metronomeMethodChannel)
        metronomeEventChannel.setStreamHandler(instance.metronomeStreamHandler)
    }

    // MARK: - FlutterStreamHandler (loop player)

    /// Called when the Dart event channel subscribes. Creates the engine.
    public func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        eventSink = events
        setupEngine()
        logger.info("Event channel opened")
        return nil
    }

    /// Called when the Dart event channel unsubscribes.
    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        logger.info("Event channel closed")
        return nil
    }

    // MARK: - Engine Setup

    /// Creates a fresh [LoopAudioEngine] and wires its callbacks to the event sink.
    private func setupEngine() {
        let eng = LoopAudioEngine()

        eng.onStateChange = { [weak self] state in
            // Dispatch to main — all Flutter event sink calls must be on main thread.
            DispatchQueue.main.async {
                self?.eventSink?(["type": "stateChange", "state": state.rawValue])
            }
        }

        eng.onError = { [weak self] error in
            DispatchQueue.main.async {
                self?.eventSink?(["type": "error", "message": error.localizedDescription])
            }
        }

        eng.onRouteChange = { [weak self] reason in
            DispatchQueue.main.async {
                self?.eventSink?(["type": "routeChange", "reason": reason])
            }
        }

        eng.onBpmDetected = { [weak self] bpmResult in
            // Already on main thread (LoopAudioEngine guarantees it), but
            // async-to-main matches the pattern used by all other callbacks.
            DispatchQueue.main.async {
                self?.eventSink?([
                    "type":        "bpmDetected",
                    "bpm":         bpmResult.bpm,
                    "confidence":  bpmResult.confidence,
                    "beats":       bpmResult.beats,
                    "beatsPerBar": bpmResult.beatsPerBar,
                    "bars":        bpmResult.bars
                ])
            }
        }

        engine = eng
        logger.info("LoopAudioEngine created")
    }

    // MARK: - FlutterPlugin Method Channel (loop player)

    /// Routes all Flutter method channel calls to [LoopAudioEngine].
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        // Lazily create engine if the event channel was never opened (e.g. hot restart).
        if engine == nil { setupEngine() }

        guard let eng = engine else {
            DispatchQueue.main.async { result(FlutterError(
                code: "ENGINE_NOT_READY",
                message: "Engine could not be initialized",
                details: nil
            )) }
            return
        }

        let args = call.arguments as? [String: Any]
        logger.debug("Method call: \(call.method)")

        switch call.method {

        // MARK: Load from absolute file path
        case "load":
            guard let path = args?["path"] as? String else {
                DispatchQueue.main.async { result(FlutterError(code: "INVALID_ARGS", message: "'path' is required", details: nil)) }
                return
            }
            let url = URL(fileURLWithPath: path)
            do {
                try eng.loadFile(url: url)
                DispatchQueue.main.async { result(nil) }
            } catch {
                logger.error("loadFile failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "LOAD_FAILED",
                        message: error.localizedDescription,
                        details: nil
                    ))
                }
            }

        // MARK: Load from Flutter asset key
        case "loadAsset":
            guard let assetKey = args?["assetKey"] as? String else {
                DispatchQueue.main.async { result(FlutterError(code: "INVALID_ARGS", message: "'assetKey' is required", details: nil)) }
                return
            }
            // Resolve the asset key to an absolute path using the Flutter asset registry.
            guard let reg = registrar else {
                DispatchQueue.main.async { result(FlutterError(code: "REGISTRAR_MISSING", message: "Plugin registrar unavailable", details: nil)) }
                return
            }
            let resolvedKey = reg.lookupKey(forAsset: assetKey)
            guard let assetPath = Bundle.main.path(forResource: resolvedKey, ofType: nil) else {
                DispatchQueue.main.async { result(FlutterError(
                    code: "ASSET_NOT_FOUND",
                    message: "Asset not found: \(assetKey)",
                    details: nil
                )) }
                return
            }
            let url = URL(fileURLWithPath: assetPath)
            do {
                try eng.loadFile(url: url)
                DispatchQueue.main.async { result(nil) }
            } catch {
                logger.error("loadAsset failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "LOAD_FAILED",
                        message: error.localizedDescription,
                        details: nil
                    ))
                }
            }

        case "play":
            eng.play()
            DispatchQueue.main.async { result(nil) }

        case "pause":
            eng.pause()
            DispatchQueue.main.async { result(nil) }

        case "resume":
            eng.resume()
            DispatchQueue.main.async { result(nil) }

        case "stop":
            eng.stop()
            DispatchQueue.main.async { result(nil) }

        case "setLoopRegion":
            guard let start = args?["start"] as? Double,
                  let end   = args?["end"]   as? Double else {
                DispatchQueue.main.async { result(FlutterError(code: "INVALID_ARGS", message: "'start' and 'end' are required", details: nil)) }
                return
            }
            do {
                try eng.setLoopRegion(start: start, end: end)
                DispatchQueue.main.async { result(nil) }
            } catch {
                logger.error("setLoopRegion failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "INVALID_REGION",
                        message: error.localizedDescription,
                        details: nil
                    ))
                }
            }

        case "setCrossfadeDuration":
            guard let dur = args?["duration"] as? Double else {
                DispatchQueue.main.async { result(FlutterError(code: "INVALID_ARGS", message: "'duration' is required", details: nil)) }
                return
            }
            eng.setCrossfadeDuration(dur)
            DispatchQueue.main.async { result(nil) }

        case "setVolume":
            guard let vol = args?["volume"] as? Double else {
                DispatchQueue.main.async { result(FlutterError(code: "INVALID_ARGS", message: "'volume' is required", details: nil)) }
                return
            }
            eng.setVolume(Float(vol))
            DispatchQueue.main.async { result(nil) }

        case "setPan":
            guard let pan = args?["pan"] as? Double else {
                DispatchQueue.main.async { result(FlutterError(code: "INVALID_ARGS", message: "'pan' is required", details: nil)) }
                return
            }
            eng.setPan(Float(pan))
            DispatchQueue.main.async { result(nil) }

        case "setPlaybackRate":
            guard let rate = args?["rate"] as? Double else {
                DispatchQueue.main.async { result(FlutterError(code: "INVALID_ARGS", message: "'rate' is required", details: nil)) }
                return
            }
            eng.setPlaybackRate(Float(rate))
            DispatchQueue.main.async { result(nil) }

        case "seek":
            guard let pos = args?["position"] as? Double else {
                DispatchQueue.main.async { result(FlutterError(code: "INVALID_ARGS", message: "'position' is required", details: nil)) }
                return
            }
            do {
                try eng.seek(to: pos)
                DispatchQueue.main.async { result(nil) }
            } catch {
                logger.error("seek failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "SEEK_FAILED",
                        message: error.localizedDescription,
                        details: nil
                    ))
                }
            }

        case "getDuration":
            let d = eng.duration
            DispatchQueue.main.async { result(d) }

        case "getCurrentPosition":
            let t = eng.currentTime
            DispatchQueue.main.async { result(t) }

        case "dispose":
            eng.dispose()
            engine = nil
            DispatchQueue.main.async { result(nil) }

        // MARK: Load from remote URL
        case "loadUrl":
            guard let urlString = args?["url"] as? String,
                  let remoteURL = URL(string: urlString) else {
                DispatchQueue.main.async { result(FlutterError(
                    code: "INVALID_ARGS",
                    message: "'url' is required and must be a valid URL",
                    details: nil
                )) }
                return
            }
            let task = URLSession.shared.dataTask(with: remoteURL) { [weak self] data, response, error in
                guard let self else { return }
                if let error {
                    self.logger.error("loadUrl download failed: \(error.localizedDescription)")
                    DispatchQueue.main.async { result(FlutterError(
                        code: "DOWNLOAD_FAILED",
                        message: error.localizedDescription,
                        details: nil
                    )) }
                    return
                }
                if let httpResponse = response as? HTTPURLResponse,
                   !(200..<300).contains(httpResponse.statusCode) {
                    self.logger.error("loadUrl download failed: HTTP \(httpResponse.statusCode): \(urlString)")
                    DispatchQueue.main.async { result(FlutterError(
                        code: "DOWNLOAD_FAILED",
                        message: "HTTP \(httpResponse.statusCode): \(urlString)",
                        details: nil
                    )) }
                    return
                }
                guard let data = data else {
                    self.logger.error("loadUrl download failed: no data received for \(urlString)")
                    DispatchQueue.main.async { result(FlutterError(
                        code: "DOWNLOAD_FAILED",
                        message: "No data received",
                        details: nil
                    )) }
                    return
                }
                let ext = remoteURL.pathExtension.isEmpty ? "wav" : remoteURL.pathExtension
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("flutter_gapless_\(Date().timeIntervalSince1970).\(ext)")
                do {
                    defer { try? FileManager.default.removeItem(at: tmp) }
                    try data.write(to: tmp)
                    try eng.loadFile(url: tmp)
                    DispatchQueue.main.async { result(nil) }
                } catch {
                    self.logger.error("loadUrl failed: \(error.localizedDescription)")
                    DispatchQueue.main.async { result(FlutterError(
                        code: "LOAD_FAILED",
                        message: error.localizedDescription,
                        details: nil
                    )) }
                }
            }
            task.resume()

        default:
            DispatchQueue.main.async { result(FlutterMethodNotImplemented) }
        }
    }

    // MARK: - Metronome Method Handler

    /// Routes calls from the `"flutter_gapless_loop/metronome"` channel.
    func handleMetronomeCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]

        switch call.method {

        case "start":
            guard let bpmVal      = args?["bpm"]          as? Double,
                  let beatsVal    = args?["beatsPerBar"]   as? Int,
                  let clickData   = args?["click"]         as? FlutterStandardTypedData,
                  let accentData  = args?["accent"]        as? FlutterStandardTypedData else {
                result(FlutterError(code: "INVALID_ARGS",
                                    message: "start requires bpm, beatsPerBar, click, accent",
                                    details: nil))
                return
            }
            let ext = args?["extension"] as? String ?? "wav"
            getOrCreateMetronomeEngine().start(
                bpm: bpmVal,
                beatsPerBar: beatsVal,
                clickData: clickData.data,
                accentData: accentData.data,
                fileExtension: ext
            )
            result(nil)

        case "setBpm":
            guard let bpmVal = args?["bpm"] as? Double else {
                result(FlutterError(code: "INVALID_ARGS", message: "'bpm' required", details: nil))
                return
            }
            metronomeEngine?.setBpm(bpmVal)
            result(nil)

        case "setBeatsPerBar":
            guard let beatsVal = args?["beatsPerBar"] as? Int else {
                result(FlutterError(code: "INVALID_ARGS", message: "'beatsPerBar' required", details: nil))
                return
            }
            metronomeEngine?.setBeatsPerBar(beatsVal)
            result(nil)

        case "stop":
            metronomeEngine?.stop()
            result(nil)

        case "dispose":
            metronomeEngine?.dispose()
            metronomeEngine = nil
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    @discardableResult
    private func getOrCreateMetronomeEngine() -> MetronomeEngine {
        if let eng = metronomeEngine { return eng }
        let eng = MetronomeEngine()
        eng.onBeatTick = { [weak self] beat in
            self?.metronomeStreamHandler.eventSink?(["type": "beatTick", "beat": beat])
        }
        eng.onError = { [weak self] msg in
            self?.metronomeStreamHandler.eventSink?(["type": "error", "message": msg])
        }
        metronomeEngine = eng
        return eng
    }
}
#endif // os(iOS)
