#if os(iOS)
import Flutter
import UIKit
import AVFoundation
import MediaPlayer
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
/// Registers the method channel and event channel, manages [LoopAudioEngine] instances
/// keyed by player ID, and routes all Flutter method calls to the correct engine.
///
/// Multiple concurrent players are supported: each Dart [LoopAudioPlayer] instance
/// includes a unique `playerId` in every method call, and all events are tagged with
/// the same `playerId` so the Dart layer can filter them without cross-talk.
public class FlutterGaplessLoopPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

    // MARK: - Private Properties

    /// Registry of active loop engines keyed by player ID.
    private var engines:    [String: LoopAudioEngine] = [:]
    /// Registry of active metronome engines keyed by player ID.
    private var metronomes: [String: MetronomeEngine] = [:]

    private var eventSink: FlutterEventSink?
    private var registrar: FlutterPluginRegistrar?
    private let logger = Logger(subsystem: "com.fluttergaplessloop", category: "Plugin")

    // Metronome
    private let metronomeStreamHandler = MetronomeStreamHandler()
    private let metronomeMethodHandler = MetronomeMethodHandler()

    // NowPlaying / remote commands
    /// The player ID that currently "owns" MPNowPlayingInfoCenter and remote commands.
    private var activePlayerId: String?
    /// True once MPRemoteCommandCenter targets have been registered (registered once).
    private var remoteCommandsRegistered = false

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

    /// Called when the Dart event channel subscribes.
    public func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        eventSink = events
        logger.info("Event channel opened")
        return nil
    }

    /// Called when the Dart event channel unsubscribes.
    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        logger.info("Event channel closed")
        return nil
    }

    // MARK: - Engine Registry

    /// Returns the existing engine for [playerId], or creates a fresh one.
    @discardableResult
    private func getOrCreateEngine(for playerId: String) -> LoopAudioEngine {
        if let eng = engines[playerId] { return eng }
        let eng = LoopAudioEngine()
        wireEngineCallbacks(eng, playerId: playerId)
        engines[playerId] = eng
        logger.info("LoopAudioEngine created for playerId=\(playerId)")
        return eng
    }

    /// Wires engine callbacks to the shared event sink, tagging each event with [playerId].
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

        eng.onInterruption = { [weak self] interruptionType in
            DispatchQueue.main.async {
                self?.eventSink?([
                    "playerId":          playerId,
                    "type":              "interruption",
                    "interruptionType":  interruptionType
                ])
            }
        }

        eng.onSeekComplete = { [weak self] position in
            DispatchQueue.main.async {
                self?.eventSink?([
                    "playerId": playerId,
                    "type":     "seekComplete",
                    "position": position
                ])
            }
        }
    }

    // MARK: - FlutterPlugin Method Channel (loop player)

    /// Routes all Flutter method channel calls to the correct [LoopAudioEngine].
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]

        // syncPlay takes an array of playerIds, not a single one — handle separately.
        if call.method == "syncPlay" {
            handleSyncPlay(args: args, result: result)
            return
        }

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

        case "setPitch":
            guard let semitones = args?["semitones"] as? Double else {
                DispatchQueue.main.async { result(FlutterError(code: "INVALID_ARGS", message: "'semitones' is required", details: nil)) }
                return
            }
            eng.setPitch(Float(semitones))
            DispatchQueue.main.async { result(nil) }

        // MARK: Tier 2 — Fade
        case "fadeTo":
            guard let targetVol = args?["targetVolume"] as? Double,
                  let durMs     = args?["durationMillis"] as? Int else {
                DispatchQueue.main.async { result(FlutterError(code: "INVALID_ARGS", message: "'targetVolume' and 'durationMillis' are required", details: nil)) }
                return
            }
            let startFromSilence = args?["startFromSilence"] as? Bool ?? false
            eng.fadeTo(targetVolume: Float(targetVol),
                       duration: Double(durMs) / 1000.0,
                       startFromSilence: startFromSilence)
            DispatchQueue.main.async { result(nil) }

        // MARK: Tier 2 — Waveform
        case "getWaveformData":
            let resolution = args?["resolution"] as? Int ?? 400
            let peaks = eng.getWaveformData(resolution: resolution)
            DispatchQueue.main.async {
                result(["resolution": peaks.count, "peaks": peaks.map { Double($0) }])
            }

        // MARK: Tier 2 — Silence detection
        case "detectSilence":
            let thresholdDb = Float(args?["thresholdDb"] as? Double ?? -60.0)
            let (start, end) = eng.detectSilence(thresholdDb: thresholdDb)
            DispatchQueue.main.async { result(["start": start, "end": end]) }

        // MARK: Tier 2 — Loudness
        case "getLoudness":
            let lufs = eng.getLoudness()
            DispatchQueue.main.async { result(["lufs": lufs]) }

        case "setNowPlayingInfo":
            setNowPlayingInfo(args: args, playerId: pid)
            DispatchQueue.main.async { result(nil) }

        case "clearNowPlayingInfo":
            clearNowPlayingInfo()
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

        default:
            DispatchQueue.main.async { result(FlutterMethodNotImplemented) }
        }
    }

    // MARK: - Sync Play

    /// Handles the `syncPlay` method, which does NOT require a single `playerId`
    /// but instead takes an array of IDs via `playerIds`.
    private func handleSyncPlay(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let ids       = args?["playerIds"] as? [String],
              let lookaheadMs = args?["lookaheadMs"] as? Int else {
            DispatchQueue.main.async { result(FlutterError(code: "INVALID_ARGS", message: "'playerIds' and 'lookaheadMs' are required", details: nil)) }
            return
        }

        // Compute the shared AVAudioTime in mach_absolute_time ticks.
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let nsPerTick = Double(info.numer) / Double(info.denom)
        let lookaheadNs = UInt64(lookaheadMs) * 1_000_000
        let lookaheadTicks = UInt64(Double(lookaheadNs) / nsPerTick)
        let hostTime = mach_absolute_time() + lookaheadTicks

        for pid in ids {
            let eng = getOrCreateEngine(for: pid)
            eng.syncPlay(hostTime: hostTime)
        }
        DispatchQueue.main.async { result(nil) }
    }

    // MARK: - Metronome Method Handler

    /// Routes calls from the `"flutter_gapless_loop/metronome"` channel.
    func handleMetronomeCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
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

    // MARK: - NowPlaying / Remote Commands

    /// Populates `MPNowPlayingInfoCenter` and registers `MPRemoteCommandCenter`
    /// targets once. Subsequent calls update the now-playing metadata only.
    private func setNowPlayingInfo(args: [String: Any]?, playerId: String) {
        activePlayerId = playerId
        setupRemoteCommands()

        var info: [String: Any] = [:]
        if let title   = args?["title"]   as? String { info[MPMediaItemPropertyTitle]        = title   }
        if let artist  = args?["artist"]  as? String { info[MPMediaItemPropertyArtist]       = artist  }
        if let album   = args?["album"]   as? String { info[MPMediaItemPropertyAlbumTitle]   = album   }
        if let dur     = args?["duration"] as? Double { info[MPMediaItemPropertyPlaybackDuration] = dur }
        if let artData = args?["artworkBytes"] as? FlutterStandardTypedData,
           let image   = UIImage(data: artData.data) {
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        logger.info("setNowPlayingInfo: title=\(info[MPMediaItemPropertyTitle] as? String ?? "(none)")")
    }

    private func clearNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        logger.info("clearNowPlayingInfo")
    }

    /// Registers MPRemoteCommandCenter targets exactly once.
    /// All commands are forwarded to the Dart layer via the event sink,
    /// tagged with `activePlayerId`. The app is responsible for acting on them.
    private func setupRemoteCommands() {
        guard !remoteCommandsRegistered else { return }
        remoteCommandsRegistered = true

        let cc = MPRemoteCommandCenter.shared()

        cc.playCommand.addTarget { [weak self] _ in
            self?.sendRemoteCommand("play")
            return .success
        }
        cc.pauseCommand.addTarget { [weak self] _ in
            self?.sendRemoteCommand("pause")
            return .success
        }
        cc.stopCommand.addTarget { [weak self] _ in
            self?.sendRemoteCommand("stop")
            return .success
        }
        cc.nextTrackCommand.addTarget { [weak self] _ in
            self?.sendRemoteCommand("nextTrack")
            return .success
        }
        cc.previousTrackCommand.addTarget { [weak self] _ in
            self?.sendRemoteCommand("previousTrack")
            return .success
        }
        cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let seekEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self?.sendRemoteCommand("seek", position: seekEvent.positionTime)
            return .success
        }
        logger.info("MPRemoteCommandCenter targets registered")
    }

    private func sendRemoteCommand(_ command: String, position: Double? = nil) {
        guard let pid = activePlayerId else { return }
        var payload: [String: Any] = [
            "playerId": pid,
            "type":     "remoteCommand",
            "command":  command
        ]
        if let pos = position { payload["position"] = pos }
        DispatchQueue.main.async { [weak self] in
            self?.eventSink?(payload)
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
#endif // os(iOS)
