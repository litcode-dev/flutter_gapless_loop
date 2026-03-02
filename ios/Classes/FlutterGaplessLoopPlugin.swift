#if os(iOS)
import Flutter
import UIKit
import AVFoundation
import os.log

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
    }

    // MARK: - FlutterStreamHandler

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
                    "type":       "bpmDetected",
                    "bpm":        bpmResult.bpm,
                    "confidence": bpmResult.confidence,
                    "beats":      bpmResult.beats
                ])
            }
        }

        engine = eng
        logger.info("LoopAudioEngine created")
    }

    // MARK: - FlutterPlugin Method Channel

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

        default:
            DispatchQueue.main.async { result(FlutterMethodNotImplemented) }
        }
    }
}
#endif // os(iOS)
