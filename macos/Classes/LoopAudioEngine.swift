import AVFoundation
import os.log

// MARK: - Public Types

/// The operational state of [LoopAudioEngine].
public enum EngineState: String {
    /// No file has been loaded. Initial state.
    case idle
    /// A file is currently being read and decoded into memory.
    case loading
    /// A file has been loaded and the engine is ready to play.
    case ready
    /// Audio is actively playing and looping.
    case playing
    /// Playback is paused. Can be resumed without reloading.
    case paused
    /// Playback has been stopped. Seek position is reset.
    case stopped
    /// An unrecoverable error occurred.
    case error
}

/// Errors thrown by [LoopAudioEngine].
public enum LoopEngineError: Error, LocalizedError {
    case fileNotFound(url: URL)
    case unsupportedFormat(format: AVAudioFormat)
    case bufferReadFailed
    case engineStartFailed(underlying: Error)
    case invalidLoopRegion(start: TimeInterval, end: TimeInterval)
    case seekOutOfBounds(requested: TimeInterval, duration: TimeInterval)
    case crossfadeTooLong(requested: TimeInterval, maximum: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "File not found: \(url.path)"
        case .unsupportedFormat(let format):
            return "Unsupported audio format: \(format)"
        case .bufferReadFailed:
            return "Failed to read audio data into buffer"
        case .engineStartFailed(let err):
            return "AVAudioEngine failed to start: \(err.localizedDescription)"
        case .invalidLoopRegion(let start, let end):
            return "Invalid loop region: start=\(start) end=\(end)"
        case .seekOutOfBounds(let requested, let duration):
            return "Seek position \(requested)s is out of bounds (duration: \(duration)s)"
        case .crossfadeTooLong(let requested, let maximum):
            return "Crossfade duration \(requested)s exceeds maximum \(maximum)s"
        }
    }
}

// MARK: - LoopAudioEngine

/// The core AVAudioEngine wrapper for sample-accurate gapless audio looping.
///
/// ## Playback Modes
///
/// The engine automatically selects one of four modes:
/// - **Mode A** (default): Full file, no crossfade. Uses `.loops` on nodeA.
/// - **Mode B**: Loop region, no crossfade. Uses `.loops` on nodeA with a sub-buffer.
/// - **Mode C**: Full file, crossfade enabled. Dual-node equal-power crossfade.
/// - **Mode D**: Loop region + crossfade enabled.
///
/// ## Thread Safety
///
/// All AVAudioEngine operations run on a dedicated serial `audioQueue`.
/// Callbacks to the Flutter layer are dispatched to `DispatchQueue.main`.
///
/// ## macOS Notes
///
/// macOS has no AVAudioSession. Output device changes (including headphone
/// plug/unplug) are observed via `AVAudioEngineConfigurationChange`. The engine
/// restarts automatically and emits an `onRouteChange` event so callers can
/// decide whether to pause.
public class LoopAudioEngine {

    // MARK: - Callbacks

    /// Called when the engine state changes.
    public var onStateChange: ((EngineState) -> Void)?

    /// Called when a non-fatal or fatal error occurs.
    public var onError: ((LoopEngineError) -> Void)?

    /// Called when the audio output device changes (e.g. headphones plugged/unplugged).
    /// The string is one of: "headphonesUnplugged", "categoryChange".
    public var onRouteChange: ((String) -> Void)?

    /// Called when BPM detection completes after a load.
    /// Always dispatched to `DispatchQueue.main`.
    public var onBpmDetected: ((BpmResult) -> Void)?

    /// Called with (rms, peak) amplitude in [0, 1] approximately 20 times per second
    /// while the engine is playing. Always dispatched to `DispatchQueue.main`.
    public var onAmplitude: ((Float, Float) -> Void)?

    // MARK: - Private: Engine Infrastructure

    private let engine = AVAudioEngine()
    private let nodeA = AVAudioPlayerNode()
    private let nodeB = AVAudioPlayerNode()   // only connected when crossfadeDuration > 0
    private let mixerNode = AVAudioMixerNode()
    private let timePitchNode = AVAudioUnitTimePitch()

    /// All AVAudioEngine operations MUST run on this queue.
    /// This serial queue acts as the synchronization mechanism — no locks needed.
    private let audioQueue = DispatchQueue(
        label: "com.fluttergaplessloop.audioqueue",
        qos: .userInteractive
    )

    private let logger = Logger(subsystem: "com.fluttergaplessloop", category: "LoopAudioEngine")

    // MARK: - Private: Buffer Hierarchy

    /// Full file, micro-fade applied at load time. Never modified after load.
    private var originalBuffer: AVAudioPCMBuffer?

    /// Trimmed to the user-specified loop region. Nil when using the full file (Mode A/C).
    private var loopBuffer: AVAudioPCMBuffer?

    /// Pre-computed equal-power crossfade ramp. Non-nil only in Modes C and D.
    private var crossfadeRamp: CrossfadeRamp?

    /// Token for the in-flight background BPM detection task.
    /// Cancelled when a new file is loaded or dispose() is called.
    private var bpmWorkItem: DispatchWorkItem?

    // MARK: - Private: Configuration

    private var crossfadeDuration: TimeInterval = 0.0
    private var loopStart: TimeInterval = 0.0
    private var loopEnd: TimeInterval = 0.0
    private var _fileDuration: TimeInterval = 0.0

    // MARK: - Private: State Machine

    private enum PlaybackMode {
        case modeA  // full file, no crossfade
        case modeB  // loop region, no crossfade
        case modeC  // full file, crossfade
        case modeD  // loop region + crossfade
    }

    private var playbackMode: PlaybackMode = .modeA
    private var _state: EngineState = .idle
    private var nodeBIsConnected: Bool = false

    /// Tracks whether the engine graph has been built. Prevents duplicate attach/connect calls.
    private var isGraphConfigured = false

    // MARK: - Private: Amplitude Tap

    private var _tapInstalled = false
    private var _lastAmplitudeTime: TimeInterval = 0

    // MARK: - Public: Computed Properties

    /// The total duration of the loaded audio file in seconds. Returns 0 if no file is loaded.
    public var duration: TimeInterval { _fileDuration }

    /// The current playback position in seconds within the loop region.
    public var currentTime: TimeInterval {
        return audioQueue.sync { [weak self] in
            guard let self else { return 0 }
            guard let nodeTime = self.nodeA.lastRenderTime,
                  let playerTime = self.nodeA.playerTime(forNodeTime: nodeTime) else {
                return self.loopStart
            }
            let activeBuffer = self.loopBuffer ?? self.originalBuffer
            guard let buf = activeBuffer else { return self.loopStart }
            let sampleRate = buf.format.sampleRate
            let loopFrames = Int64(buf.frameLength)
            guard loopFrames > 0 else { return self.loopStart }
            let rawFrame = max(0, playerTime.sampleTime)
            let wrappedFrame = rawFrame % loopFrames
            return self.loopStart + Double(wrappedFrame) / sampleRate
        }
    }

    /// The current engine state.
    public var state: EngineState { _state }

    // MARK: - Initialization

    public init() {}

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public API

    /// Loads an audio file from a URL into memory.
    ///
    /// Applies a 5ms micro-fade to the head and tail of the buffer at load time
    /// to prevent clicks at the loop boundary. This runs once and costs nothing
    /// at runtime.
    ///
    /// - Parameter url: The absolute URL of a WAV or PCM audio file.
    /// - Throws: `LoopEngineError` if the file cannot be read or the engine fails to start.
    public func loadFile(url: URL) throws {
        logger.info("loadFile: \(url.lastPathComponent)")
        bpmWorkItem?.cancel()

        // Phase 1: I/O off queue — safe since we only READ the file
        setState(.loading)

        guard FileManager.default.fileExists(atPath: url.path) else {
            setState(.error)
            throw LoopEngineError.fileNotFound(url: url)
        }

        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch {
            setState(.error)
            throw LoopEngineError.engineStartFailed(underlying: error)
        }

        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            setState(.error)
            throw LoopEngineError.bufferReadFailed
        }
        do { try file.read(into: buffer) } catch {
            setState(.error)
            throw LoopEngineError.bufferReadFailed
        }
        applyMicroFade(to: buffer)

        let computedDuration = Double(file.length) / format.sampleRate

        // Phase 2: Commit all state changes on the serial queue to prevent data races.
        var engineStartError: Error? = nil
        audioQueue.sync { [weak self] in
            guard let self else { return }
            self.nodeA.stop()
            if self.nodeBIsConnected { self.nodeB.stop() }

            self.originalBuffer = buffer
            self._fileDuration = computedDuration
            self.loopEnd = computedDuration
            self.loopStart = 0.0
            self.loopBuffer = nil
            self.crossfadeRamp = nil
            self.playbackMode = self.crossfadeDuration > 0 ? .modeC : .modeA

            if !self.isGraphConfigured {
                self.setupEngineGraph(format: format)
                self.isGraphConfigured = true
            }
            if !self.engine.isRunning {
                do {
                    try self.engine.start()
                } catch {
                    engineStartError = error
                }
            }
            if engineStartError == nil {
                self.setState(.ready)
            } else {
                self.setState(.error)
            }
        }

        if let err = engineStartError {
            throw LoopEngineError.engineStartFailed(underlying: err)
        }
        triggerBpmDetection(buffer: buffer)
        logger.info("loadFile complete: duration=\(computedDuration)s")
    }

    /// Starts gapless loop playback.
    public func play() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            guard self._state == .ready || self._state == .stopped else {
                self.logger.warning("play() ignored: state is \(self._state.rawValue)")
                return
            }
            self.scheduleForCurrentMode()
            self.nodeA.play()
            self.setState(.playing)
            self.installAmplitudeTap()
            self.logger.info("play: mode=\(String(describing: self.playbackMode))")
        }
    }

    /// Pauses playback at the current position.
    public func pause() {
        audioQueue.async { [weak self] in
            guard let self, self._state == .playing else { return }
            self.removeAmplitudeTap()
            self.nodeA.pause()
            if self.nodeBIsConnected { self.nodeB.pause() }
            self.setState(.paused)
            self.logger.info("pause")
        }
    }

    /// Resumes paused playback.
    public func resume() {
        audioQueue.async { [weak self] in
            guard let self, self._state == .paused else { return }
            self.nodeA.play()
            if self.nodeBIsConnected { self.nodeB.play() }
            self.setState(.playing)
            self.installAmplitudeTap()
            self.logger.info("resume")
        }
    }

    /// Stops playback and resets the scheduling state.
    public func stop() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.removeAmplitudeTap()
            self.nodeA.stop()
            if self.nodeBIsConnected { self.nodeB.stop() }
            self.setState(.stopped)
            self.logger.info("stop")
        }
    }

    /// Sets the loop region in seconds.
    public func setLoopRegion(start: TimeInterval, end: TimeInterval) throws {
        var capturedBuffer: AVAudioPCMBuffer? = nil
        var capturedDuration: TimeInterval = 0
        audioQueue.sync { [weak self] in
            guard let self else { return }
            capturedBuffer = self.originalBuffer
            capturedDuration = self._fileDuration
        }

        guard let original = capturedBuffer else {
            throw LoopEngineError.bufferReadFailed
        }
        guard start >= 0, end > start, end <= capturedDuration else {
            throw LoopEngineError.invalidLoopRegion(start: start, end: end)
        }

        let subBuffer = try extractSubBuffer(from: original, start: start, end: end)
        applyMicroFade(to: subBuffer)
        alignToZeroCrossings(buffer: subBuffer)

        audioQueue.async { [weak self] in
            guard let self else { return }
            self.loopStart = start
            self.loopEnd = end
            self.loopBuffer = subBuffer

            if self.crossfadeDuration > 0 {
                let regionDuration = end - start
                let maxCrossfade = regionDuration * 0.5
                let clampedDuration = min(self.crossfadeDuration, maxCrossfade)
                self.crossfadeRamp = CrossfadeRamp(
                    duration: clampedDuration,
                    sampleRate: subBuffer.format.sampleRate
                )
                self.playbackMode = .modeD
            } else {
                self.playbackMode = .modeB
            }

            if self._state == .playing {
                self.nodeA.stop()
                self.scheduleForCurrentMode()
                self.nodeA.play()
            }
            self.logger.info("setLoopRegion: \(start)–\(end)s mode=\(String(describing: self.playbackMode))")
        }
    }

    /// Sets the crossfade duration. Pass 0.0 to disable (default).
    public func setCrossfadeDuration(_ duration: TimeInterval) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.crossfadeDuration = duration

            if duration > 0 {
                if !self.nodeBIsConnected, let format = self.originalBuffer?.format {
                    self.engine.attach(self.nodeB)
                    self.engine.connect(self.nodeB, to: self.mixerNode, format: format)
                    self.nodeBIsConnected = true
                    self.logger.info("nodeB attached for crossfade")
                }

                let activeBuf = self.loopBuffer ?? self.originalBuffer
                if let buf = activeBuf {
                    let bufDuration = Double(buf.frameLength) / buf.format.sampleRate
                    let maxCrossfade = bufDuration * 0.5
                    let clamped = min(duration, maxCrossfade)
                    self.crossfadeRamp = CrossfadeRamp(
                        duration: clamped,
                        sampleRate: buf.format.sampleRate
                    )
                }
                self.playbackMode = self.loopBuffer != nil ? .modeD : .modeC
            } else {
                self.crossfadeRamp = nil
                self.playbackMode = self.loopBuffer != nil ? .modeB : .modeA
            }
            self.logger.info("setCrossfadeDuration: \(duration)s mode=\(String(describing: self.playbackMode))")
        }
    }

    /// Sets the output volume. Range: 0.0 (silent) to 1.0 (full).
    public func setVolume(_ volume: Float) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.mixerNode.outputVolume = max(0.0, min(1.0, volume))
        }
    }

    /// Sets the stereo pan position. Range: -1.0 (full left) to 1.0 (full right).
    public func setPan(_ pan: Float) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.mixerNode.pan = max(-1.0, min(1.0, pan))
        }
    }

    /// Sets the playback rate (speed) while preserving pitch.
    public func setPlaybackRate(_ rate: Float) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.timePitchNode.rate = max(0.03125, min(32.0, rate))
        }
    }

    /// Seeks to a position within the loaded file.
    public func seek(to time: TimeInterval) throws {
        guard time >= 0, time < _fileDuration else {
            throw LoopEngineError.seekOutOfBounds(requested: time, duration: _fileDuration)
        }

        audioQueue.async { [weak self] in
            guard let self else { return }
            let wasPlaying = self._state == .playing
            self.nodeA.stop()

            let activeBuffer = self.loopBuffer ?? self.originalBuffer
            guard let buf = activeBuffer else { return }

            let effectiveEnd = self.loopBuffer != nil ? self.loopEnd : self._fileDuration
            if let remaining = try? self.extractSubBuffer(from: buf, start: time, end: effectiveEnd) {
                self.nodeA.scheduleBuffer(remaining, at: nil, options: []) { [weak self] in
                    guard let self else { return }
                    self.audioQueue.async {
                        self.nodeA.scheduleBuffer(buf, at: nil, options: .loops, completionHandler: nil)
                    }
                }
            } else {
                self.scheduleForCurrentMode()
            }

            if wasPlaying { self.nodeA.play() }
            self.logger.info("seek: \(time)s")
        }
    }

    /// Releases all native resources. The engine cannot be used after this call.
    public func dispose() {
        bpmWorkItem?.cancel()
        bpmWorkItem = nil
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.removeAmplitudeTap()
            self.nodeA.stop()
            if self.nodeBIsConnected { self.nodeB.stop() }
            self.engine.stop()
            self.originalBuffer = nil
            self.loopBuffer = nil
            self.crossfadeRamp = nil
            NotificationCenter.default.removeObserver(self)
            self.setState(.idle)
            self.logger.info("dispose")
        }
    }

    // MARK: - Private: Engine Graph

    /// Builds the audio graph: nodeA → mixerNode → timePitchNode → mainMixerNode → outputNode.
    /// Registers for AVAudioEngineConfigurationChange to handle device changes.
    private func setupEngineGraph(format: AVAudioFormat) {
        engine.attach(nodeA)
        engine.attach(mixerNode)
        engine.connect(nodeA, to: mixerNode, format: format)
        engine.attach(timePitchNode)
        engine.connect(mixerNode, to: timePitchNode, format: format)
        engine.connect(timePitchNode, to: engine.mainMixerNode, format: nil)

        // On macOS, AVAudioEngine stops when the output device changes.
        // Re-start the engine and re-schedule so playback continues on the new device.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEngineConfigurationChange(_:)),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
        logger.debug("Engine graph configured: nodeA → mixerNode → timePitch → mainMixer → output")
    }

    // MARK: - Private: macOS Device Change

    /// Handles audio device changes (headphones plugged/unplugged, USB audio, etc.).
    ///
    /// On macOS, `AVAudioEngineConfigurationChange` fires whenever the hardware
    /// configuration changes. The engine is stopped automatically by the system.
    /// This handler restarts the engine and re-schedules if playback was active,
    /// then emits an `onRouteChange` event so callers can decide whether to pause.
    @objc private func handleEngineConfigurationChange(_ notification: Notification) {
        audioQueue.async { [weak self] in
            guard let self, self.isGraphConfigured else { return }
            let wasPlaying = self._state == .playing
            do {
                try self.engine.start()
                if wasPlaying {
                    self.scheduleForCurrentMode()
                    self.nodeA.play()
                    if self.nodeBIsConnected { self.nodeB.play() }
                }
            } catch {
                self.logger.error("Failed to restart engine after configuration change: \(error)")
                self.setState(.error)
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.onRouteChange?("headphonesUnplugged")
            }
            self.logger.info("Engine configuration changed: audio device changed")
        }
    }

    // MARK: - Private: Scheduling

    private func scheduleForCurrentMode() {
        switch playbackMode {
        case .modeA:
            guard let buf = originalBuffer else { return }
            nodeA.scheduleBuffer(buf, at: nil, options: .loops, completionHandler: nil)

        case .modeB:
            guard let buf = loopBuffer else { return }
            nodeA.scheduleBuffer(buf, at: nil, options: .loops, completionHandler: nil)

        case .modeC:
            guard let buf = originalBuffer else { return }
            scheduleCrossfade(buffer: buf)

        case .modeD:
            guard let buf = loopBuffer else { return }
            scheduleCrossfade(buffer: buf)
        }
    }

    private func scheduleCrossfade(buffer: AVAudioPCMBuffer) {
        guard let ramp = crossfadeRamp else {
            nodeA.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
            return
        }

        let bufDuration = Double(buffer.frameLength) / buffer.format.sampleRate
        let crossfadeSecs = Double(ramp.frameCount) / buffer.format.sampleRate
        let tailStart = bufDuration - crossfadeSecs

        guard tailStart > 0,
              let tailBuffer = try? extractSubBuffer(from: buffer, start: tailStart, end: bufDuration),
              let headBuffer = try? extractSubBuffer(from: buffer, start: 0, end: crossfadeSecs) else {
            nodeA.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
            return
        }

        CrossfadeEngine.apply(ramp: ramp, primary: tailBuffer, secondary: headBuffer)
        nodeA.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        scheduleNodeBCrossfade(headBuffer: headBuffer, loopDuration: bufDuration, crossfadeSecs: crossfadeSecs)
    }

    private func scheduleNodeBCrossfade(headBuffer: AVAudioPCMBuffer, loopDuration: Double, crossfadeSecs: Double) {
        guard nodeBIsConnected, crossfadeDuration > 0 else { return }

        guard let lastRender = nodeA.lastRenderTime,
              let playerTime = nodeA.playerTime(forNodeTime: lastRender) else {
            nodeB.scheduleBuffer(headBuffer, at: nil, options: []) { [weak self] in
                guard let self else { return }
                self.audioQueue.async {
                    self.scheduleNodeBCrossfade(
                        headBuffer: headBuffer,
                        loopDuration: loopDuration,
                        crossfadeSecs: crossfadeSecs
                    )
                }
            }
            if !nodeB.isPlaying { nodeB.play() }
            return
        }

        let sampleRate = headBuffer.format.sampleRate
        let rawSample = playerTime.sampleTime
        let currentSample = max(0, rawSample)
        let loopFrames = Int64(loopDuration * sampleRate)
        let crossfadeFrames = Int64(crossfadeSecs * sampleRate)

        let positionInLoop = currentSample % loopFrames
        let framesUntilBoundary = loopFrames - positionInLoop
        let framesUntilCrossfadeStart = framesUntilBoundary - crossfadeFrames
        let startSample = currentSample + max(0, framesUntilCrossfadeStart)
        let startTime = AVAudioTime(sampleTime: startSample, atRate: sampleRate)

        if !nodeB.isPlaying { nodeB.play() }

        nodeB.scheduleBuffer(headBuffer, at: startTime, options: []) { [weak self] in
            guard let self else { return }
            self.audioQueue.async {
                self.scheduleNodeBCrossfade(
                    headBuffer: headBuffer,
                    loopDuration: loopDuration,
                    crossfadeSecs: crossfadeSecs
                )
            }
        }
    }

    // MARK: - Private: Buffer Processing

    private func applyMicroFade(to buffer: AVAudioPCMBuffer) {
        let format = buffer.format
        let channelCount = Int(format.channelCount)
        let totalFrames = Int(buffer.frameLength)
        let fadeLengthFrames = min(Int(format.sampleRate * 0.005), totalFrames / 2)

        guard fadeLengthFrames > 0, let channelData = buffer.floatChannelData else { return }

        for ch in 0..<channelCount {
            let data = channelData[ch]
            for i in 0..<fadeLengthFrames {
                let gain = Float(i) / Float(fadeLengthFrames)
                data[i] *= gain
            }
            for i in 0..<fadeLengthFrames {
                let gain = Float(i) / Float(fadeLengthFrames)
                data[totalFrames - 1 - i] *= gain
            }
        }
    }

    private func alignToZeroCrossings(buffer: AVAudioPCMBuffer) {
        let sampleRate = buffer.format.sampleRate
        let windowFrames = Int(sampleRate * 0.010)
        let totalFrames = Int(buffer.frameLength)
        guard totalFrames > 0, let data = buffer.floatChannelData else { return }
        let ch0 = data[0]

        var fadeStart = 0
        for i in 1..<min(windowFrames, totalFrames) {
            if ch0[i - 1] <= 0 && ch0[i] >= 0 {
                fadeStart = i
                break
            }
        }

        var fadeEnd = totalFrames
        for i in stride(from: totalFrames - 1, through: max(totalFrames - windowFrames, 1), by: -1) {
            if ch0[i] <= 0 && ch0[i - 1] >= 0 {
                fadeEnd = i
                break
            }
        }

        let channelCount = Int(buffer.format.channelCount)
        for ch in 0..<channelCount {
            let d = data[ch]
            for i in 0..<fadeStart { d[i] = 0 }
            for i in fadeEnd..<totalFrames { d[i] = 0 }
        }
    }

    private func extractSubBuffer(from source: AVAudioPCMBuffer,
                                  start: TimeInterval,
                                  end: TimeInterval) throws -> AVAudioPCMBuffer {
        let sampleRate = source.format.sampleRate
        let startFrame = AVAudioFrameCount(start * sampleRate)
        let endFrame   = AVAudioFrameCount(end   * sampleRate)
        let frameCount = endFrame > startFrame ? endFrame - startFrame : 0

        guard frameCount > 0,
              startFrame < source.frameLength,
              let sub = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: frameCount),
              let srcData = source.floatChannelData,
              let dstData = sub.floatChannelData else {
            throw LoopEngineError.bufferReadFailed
        }

        let channelCount = Int(source.format.channelCount)
        for ch in 0..<channelCount {
            let src = srcData[ch].advanced(by: Int(startFrame))
            let dst = dstData[ch]
            dst.initialize(from: src, count: Int(frameCount))
        }
        sub.frameLength = frameCount
        return sub
    }

    // MARK: - Private: State

    private func setState(_ newState: EngineState) {
        guard _state != newState else { return }
        _state = newState
        logger.debug("state → \(newState.rawValue)")
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(newState)
        }
    }

    // MARK: - Private: Amplitude Tap

    private func installAmplitudeTap() {
        guard !_tapInstalled else { return }
        guard onAmplitude != nil else { return }
        _tapInstalled = true
        _lastAmplitudeTime = 0

        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self, let onAmplitude = self.onAmplitude else { return }

            let now = Date.timeIntervalSinceReferenceDate
            guard now - self._lastAmplitudeTime >= 0.05 else { return }
            self._lastAmplitudeTime = now

            guard let channelData = buffer.floatChannelData else { return }
            let frameCount = Int(buffer.frameLength)
            let channelCount = Int(buffer.format.channelCount)
            guard frameCount > 0 else { return }

            var sumSquares: Float = 0
            var peak: Float = 0
            let totalSamples = frameCount * channelCount
            for ch in 0..<channelCount {
                let data = channelData[ch]
                for i in 0..<frameCount {
                    let s = data[i]
                    sumSquares += s * s
                    let abs = s < 0 ? -s : s
                    if abs > peak { peak = abs }
                }
            }
            let rms = (sumSquares / Float(totalSamples)).squareRoot()

            DispatchQueue.main.async {
                onAmplitude(min(rms, 1.0), min(peak, 1.0))
            }
        }
        logger.debug("Amplitude tap installed")
    }

    private func removeAmplitudeTap() {
        guard _tapInstalled else { return }
        _tapInstalled = false
        engine.mainMixerNode.removeTap(onBus: 0)
        logger.debug("Amplitude tap removed")
    }

    // MARK: - Private: BPM Detection

    private func triggerBpmDetection(buffer: AVAudioPCMBuffer) {
        var workItem: DispatchWorkItem!
        workItem = DispatchWorkItem { [weak self] in
            let result = BpmDetector.detect(buffer: buffer)
            guard !workItem.isCancelled else { return }
            DispatchQueue.main.async { [weak self] in
                self?.onBpmDetected?(result)
            }
        }
        bpmWorkItem = workItem
        DispatchQueue.global(qos: .utility).async(execute: workItem)
    }
}
