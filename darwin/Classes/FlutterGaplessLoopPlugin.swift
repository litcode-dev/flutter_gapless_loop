#if os(iOS)
import Flutter
import UIKit
#else
import FlutterMacOS
#endif
import AVFoundation
import os.log

// File-scope — must be outside any class or function body.
#if os(iOS)
private extension FlutterPluginRegistrar {
    var messengerBridge: FlutterBinaryMessenger { messenger() }
}
#else
private extension FlutterPluginRegistrar {
    var messengerBridge: FlutterBinaryMessenger { messenger }
}
#endif

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

/// The Flutter plugin entry point for flutter_gapless_loop (iOS and macOS).
///
/// Registers the method channel and event channel, manages [LoopAudioEngine] instances
/// keyed by player ID, and routes all Flutter method calls to the correct engine.
///
/// Multiple concurrent players are supported: each Dart [LoopAudioPlayer] instance
/// includes a unique `playerId` in every method call, and all events are tagged with
/// the same `playerId` so the Dart layer can filter them without cross-talk.
public class FlutterGaplessLoopPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

    // MARK: - Private Properties

    private var engines:    [String: LoopAudioEngine] = [:]
    private var metronomes: [String: MetronomeEngine] = [:]

    private var eventSink: FlutterEventSink?
    private var registrar: FlutterPluginRegistrar?
    private let logger = Logger(subsystem: "com.fluttergaplessloop", category: "Plugin")

    private let metronomeStreamHandler = MetronomeStreamHandler()
    private let metronomeMethodHandler = MetronomeMethodHandler()

    // MARK: - FlutterPlugin Registration

    public static func register(with registrar: FlutterPluginRegistrar) {
        let methodChannel = FlutterMethodChannel(
            name: "flutter_gapless_loop",
            binaryMessenger: registrar.messengerBridge
        )
        let eventChannel = FlutterEventChannel(
            name: "flutter_gapless_loop/events",
            binaryMessenger: registrar.messengerBridge
        )

        let instance = FlutterGaplessLoopPlugin()
        instance.registrar = registrar
        registrar.addMethodCallDelegate(instance, channel: methodChannel)
        eventChannel.setStreamHandler(instance)

        // Metronome channels — separate handler to avoid method-name collisions
        let metronomeMethodChannel = FlutterMethodChannel(
            name: "flutter_gapless_loop/metronome",
            binaryMessenger: registrar.messengerBridge
        )
        let metronomeEventChannel = FlutterEventChannel(
            name: "flutter_gapless_loop/metronome/events",
            binaryMessenger: registrar.messengerBridge
        )
        instance.metronomeMethodHandler.plugin = instance
        registrar.addMethodCallDelegate(instance.metronomeMethodHandler,
                                        channel: metronomeMethodChannel)
        metronomeEventChannel.setStreamHandler(instance.metronomeStreamHandler)
    }

    // MARK: - FlutterPlugin Lifecycle

#if os(iOS)
    /// Called when the engine detaches (hot-restart). Resets the one-time session-configuration
    /// guard so the next engine instance can reconfigure AVAudioSession cleanly.
    public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
        engines.values.forEach    { $0.dispose() }
        engines.removeAll()
        metronomes.values.forEach { $0.dispose() }
        metronomes.removeAll()
        LoopAudioEngine.sessionConfigured = false
        logger.info("Plugin detached — session config flag reset")
    }
#endif

    // MARK: - FlutterStreamHandler (loop player)

    public func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        eventSink = events
        logger.info("Event channel opened")
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        logger.info("Event channel closed")
        return nil
    }

    // MARK: - Engine Registry

    @discardableResult
    private func getOrCreateEngine(for playerId: String) -> LoopAudioEngine {
        if let eng = engines[playerId] { return eng }
        let eng = LoopAudioEngine()
        wireEngineCallbacks(eng, playerId: playerId)
        engines[playerId] = eng
        logger.info("LoopAudioEngine created for playerId=\(playerId)")
        return eng
    }

    private func wireEngineCallbacks(_ eng: LoopAudioEngine, playerId: String) {
        eng.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                self?.eventSink?([
                    "playerId": playerId,
                    "type":     "stateChange",
                    "state":    state.rawValue
                ])
            }
        }

        eng.onError = { [weak self] error in
            DispatchQueue.main.async {
                self?.eventSink?([
                    "playerId": playerId,
                    "type":     "error",
                    "message":  error.localizedDescription
                ])
            }
        }

        eng.onRouteChange = { [weak self] reason in
            DispatchQueue.main.async {
                self?.eventSink?([
                    "playerId": playerId,
                    "type":     "routeChange",
                    "reason":   reason
                ])
            }
        }

        eng.onBpmDetected = { [weak self] bpmResult in
            DispatchQueue.main.async {
                self?.eventSink?([
                    "playerId":    playerId,
                    "type":        "bpmDetected",
                    "bpm":         bpmResult.bpm,
                    "confidence":  bpmResult.confidence,
                    "beats":       bpmResult.beats,
                    "beatsPerBar": bpmResult.beatsPerBar,
                    "bars":        bpmResult.bars
                ])
            }
        }

        eng.onAmplitude = { [weak self] rms, peak in
            // Already dispatched to main by LoopAudioEngine.
            self?.eventSink?([
                "playerId": playerId,
                "type":     "amplitude",
                "rms":      rms,
                "peak":     peak
            ])
        }

        eng.onSeekComplete = { [weak self] position in
            // Already dispatched to main by LoopAudioEngine.
            self?.eventSink?([
                "playerId": playerId,
                "type":     "seekComplete",
                "position": position
            ])
        }

        eng.onInterruption = { [weak self] interruptionType, shouldResume in
            // Already dispatched to main by LoopAudioEngine.
            self?.eventSink?([
                "playerId":         playerId,
                "type":             "interruption",
                "interruptionType": interruptionType,
                "shouldResume":     shouldResume
            ])
        }

        eng.onSpectrum = { [weak self] magnitudes in
            // Already dispatched to main by LoopAudioEngine.
            self?.eventSink?([
                "playerId":   playerId,
                "type":       "spectrum",
                "magnitudes": magnitudes
            ])
        }
    }

    // MARK: - FlutterPlugin Method Channel (loop player)

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        // clearAll has no playerId — handle before the per-player routing
        if call.method == "clearAll" {
            engines.values.forEach    { $0.dispose() }
            engines.removeAll()
            metronomes.values.forEach { $0.dispose() }
            metronomes.removeAll()
            DispatchQueue.main.async { result(nil) }
            return
        }

        let args = call.arguments as? [String: Any]
        guard let pid = args?["playerId"] as? String else {
            DispatchQueue.main.async { result(FlutterError(
                code: "INVALID_ARGS",
                message: "'playerId' is required",
                details: nil
            )) }
            return
        }

        let eng = getOrCreateEngine(for: pid)
        logger.debug("Method call: \(call.method) pid=\(pid)")

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
            engines.removeValue(forKey: pid)
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
            guard remoteURL.scheme == "https" || remoteURL.scheme == "http" else {
                DispatchQueue.main.async { result(FlutterError(
                    code: "INVALID_ARGS",
                    message: "URL must use http or https scheme: \(urlString)",
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
                    .appendingPathComponent("flutter_gapless_\(UUID().uuidString).\(ext)")
                defer { try? FileManager.default.removeItem(at: tmp) }
                do {
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

        // MARK: - Tier 1: setPitch
        case "setPitch":
            guard let semitones = args?["semitones"] as? Double else {
                DispatchQueue.main.async { result(FlutterError(code: "INVALID_ARGS", message: "'semitones' is required", details: nil)) }
                return
            }
            eng.setPitch(Float(semitones))
            DispatchQueue.main.async { result(nil) }

        // MARK: - Tier 1: fadeTo
        case "fadeTo":
            guard let targetVolume = args?["targetVolume"] as? Double,
                  let durationMs   = args?["durationMs"]   as? Int else {
                DispatchQueue.main.async { result(FlutterError(code: "INVALID_ARGS", message: "'targetVolume' and 'durationMs' are required", details: nil)) }
                return
            }
            eng.fadeTo(targetVolume: Float(targetVolume), durationMs: durationMs)
            DispatchQueue.main.async { result(nil) }

        // MARK: - Tier 1: NowPlayingInfo
        case "setNowPlayingInfo":
            // Stub: NowPlayingInfo requires MediaPlayer / MPNowPlayingInfoCenter wiring
            // which is outside the scope of LoopAudioEngine. Accept call silently.
            DispatchQueue.main.async { result(nil) }

        case "clearNowPlayingInfo":
            DispatchQueue.main.async { result(nil) }

        // MARK: - Tier 1: RemoteCommands
        case "enableRemoteCommands":
            DispatchQueue.main.async { result(nil) }

        case "disableRemoteCommands":
            DispatchQueue.main.async { result(nil) }

        // MARK: - Tier 2: Waveform data
        case "getWaveformData":
            let numSamples = args?["numSamples"] as? Int ?? 1024
            let waveform = eng.getWaveformData(numSamples: numSamples)
            DispatchQueue.main.async { result(waveform) }

        // MARK: - Tier 2: Silence detection
        case "detectSilence":
            let threshold   = (args?["threshold"]   as? Double).map(Float.init) ?? 0.01
            let minDuration = args?["minDuration"]   as? Double ?? 0.1
            let regions = eng.detectSilenceRegions(threshold: threshold, minDuration: minDuration)
            DispatchQueue.main.async { result(regions) }

        case "trimSilence":
            let threshold   = (args?["threshold"]   as? Double).map(Float.init) ?? 0.01
            let minDuration = args?["minDuration"]   as? Double ?? 0.05
            eng.trimSilence(threshold: threshold, minDuration: minDuration)
            DispatchQueue.main.async { result(nil) }

        // MARK: - Tier 2: Loudness
        case "getLoudness":
            let lufs = eng.getLoudness()
            DispatchQueue.main.async { result(lufs) }

        case "normaliseLoudness":
            let targetLufs = args?["targetLufs"] as? Double ?? -14.0
            eng.normaliseLoudness(targetLufs: targetLufs)
            DispatchQueue.main.async { result(nil) }

        // MARK: - Tier 3: EQ
        case "setEq":
            let low  = (args?["low"]  as? Double).map(Float.init) ?? 0
            let mid  = (args?["mid"]  as? Double).map(Float.init) ?? 0
            let high = (args?["high"] as? Double).map(Float.init) ?? 0
            eng.setEq(low: low, mid: mid, high: high)
            DispatchQueue.main.async { result(nil) }

        case "resetEq":
            eng.resetEq()
            DispatchQueue.main.async { result(nil) }

        // MARK: - Tier 3: Reverb
        case "setReverb":
            guard let presetIndex = args?["preset"] as? Int,
                  let wetMix      = args?["wetMix"]  as? Double else {
                DispatchQueue.main.async { result(FlutterError(code: "INVALID_ARGS", message: "'preset' and 'wetMix' are required", details: nil)) }
                return
            }
            eng.setReverb(presetIndex: presetIndex, wetMix: Float(wetMix))
            DispatchQueue.main.async { result(nil) }

        case "disableReverb":
            eng.disableReverb()
            DispatchQueue.main.async { result(nil) }

        // MARK: - Tier 3: Compressor
        case "setCompressor":
            let threshold  = (args?["threshold"]  as? Double).map(Float.init) ?? -20
            let makeupGain = (args?["makeupGain"]  as? Double).map(Float.init) ?? 0
            let attackMs   = (args?["attackMs"]    as? Double).map(Float.init) ?? 10
            let releaseMs  = (args?["releaseMs"]   as? Double).map(Float.init) ?? 100
            eng.setCompressor(threshold: threshold, makeupGain: makeupGain, attackMs: attackMs, releaseMs: releaseMs)
            DispatchQueue.main.async { result(nil) }

        case "disableCompressor":
            eng.disableCompressor()
            DispatchQueue.main.async { result(nil) }

        // MARK: - Tier 3: FFT Spectrum
        case "enableSpectrum":
            eng.enableSpectrum()
            DispatchQueue.main.async { result(nil) }

        case "disableSpectrum":
            eng.disableSpectrum()
            DispatchQueue.main.async { result(nil) }

        // MARK: - Tier 3: WAV Export
        case "exportToFile":
            guard let outputPath = args?["outputPath"] as? String else {
                DispatchQueue.main.async { result(FlutterError(code: "INVALID_ARGS", message: "'outputPath' is required", details: nil)) }
                return
            }
            let format      = args?["format"]      as? Int
            let regionStart = args?["regionStart"] as? Double
            let regionEnd   = args?["regionEnd"]   as? Double
            let outputURL   = URL(fileURLWithPath: outputPath)
            do {
                try eng.exportToFile(url: outputURL, format: format ?? 0,
                                     regionStart: regionStart, regionEnd: regionEnd)
                DispatchQueue.main.async { result(nil) }
            } catch {
                logger.error("exportToFile failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    result(FlutterError(code: "EXPORT_FAILED", message: error.localizedDescription, details: nil))
                }
            }

        // MARK: - Tier 3: Sync group
        case "syncPlayAll":
            guard let playerIds = args?["playerIds"] as? [String] else {
                DispatchQueue.main.async { result(FlutterError(code: "INVALID_ARGS", message: "'playerIds' is required", details: nil)) }
                return
            }
            let targetEngines = playerIds.compactMap { engines[$0] }
            guard !targetEngines.isEmpty else {
                DispatchQueue.main.async { result(nil) }
                return
            }
            // Use AVAudioTime on the host clock for sample-accurate start (+10 ms)
            var timebaseInfo = mach_timebase_info_data_t()
            mach_timebase_info(&timebaseInfo)
            let nanos: UInt64 = 10_000_000 // 10 ms
            let ticks = nanos * UInt64(timebaseInfo.denom) / UInt64(timebaseInfo.numer)
            let avTime = AVAudioTime(hostTime: mach_absolute_time() + ticks)
            for e in targetEngines { e.playAtTime(avTime) }
            DispatchQueue.main.async { result(nil) }

        case "syncPauseAll":
            guard let playerIds = args?["playerIds"] as? [String] else {
                DispatchQueue.main.async { result(FlutterError(code: "INVALID_ARGS", message: "'playerIds' is required", details: nil)) }
                return
            }
            playerIds.compactMap { engines[$0] }.forEach { $0.pause() }
            DispatchQueue.main.async { result(nil) }

        case "syncStopAll":
            guard let playerIds = args?["playerIds"] as? [String] else {
                DispatchQueue.main.async { result(FlutterError(code: "INVALID_ARGS", message: "'playerIds' is required", details: nil)) }
                return
            }
            playerIds.compactMap { engines[$0] }.forEach { $0.stop() }
            DispatchQueue.main.async { result(nil) }

        default:
            DispatchQueue.main.async { result(FlutterMethodNotImplemented) }
        }
    }

    // MARK: - Metronome Method Handler

    func handleMetronomeCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        // clearAll has no playerId — handle before the per-player routing
        if call.method == "clearAll" {
            metronomes.values.forEach { $0.dispose() }
            metronomes.removeAll()
            result(nil)
            return
        }

        let args = call.arguments as? [String: Any]
        guard let pid = args?["playerId"] as? String else {
            result(FlutterError(code: "INVALID_ARGS", message: "'playerId' is required", details: nil))
            return
        }

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
            getOrCreateMetronomeEngine(for: pid).start(
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
            metronomes[pid]?.setBpm(bpmVal)
            result(nil)

        case "setBeatsPerBar":
            guard let beatsVal = args?["beatsPerBar"] as? Int else {
                result(FlutterError(code: "INVALID_ARGS", message: "'beatsPerBar' required", details: nil))
                return
            }
            metronomes[pid]?.setBeatsPerBar(beatsVal)
            result(nil)

        case "setVolume":
            guard let vol = args?["volume"] as? Double else {
                result(FlutterError(code: "INVALID_ARGS", message: "'volume' required", details: nil))
                return
            }
            metronomes[pid]?.setVolume(Float(vol))
            result(nil)

        case "setPan":
            guard let pan = args?["pan"] as? Double else {
                result(FlutterError(code: "INVALID_ARGS", message: "'pan' required", details: nil))
                return
            }
            metronomes[pid]?.setPan(Float(pan))
            result(nil)

        case "stop":
            metronomes[pid]?.stop()
            result(nil)

        case "dispose":
            metronomes[pid]?.dispose()
            metronomes.removeValue(forKey: pid)
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    @discardableResult
    private func getOrCreateMetronomeEngine(for playerId: String) -> MetronomeEngine {
        if let eng = metronomes[playerId] { return eng }
        let eng = MetronomeEngine()
        eng.onBeatTick = { [weak self] beat in
            self?.metronomeStreamHandler.eventSink?(
                ["playerId": playerId, "type": "beatTick", "beat": beat])
        }
        eng.onError = { [weak self] msg in
            self?.metronomeStreamHandler.eventSink?(
                ["playerId": playerId, "type": "error", "message": msg])
        }
        metronomes[playerId] = eng
        return eng
    }
}
