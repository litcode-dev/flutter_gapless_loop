#if os(iOS)
import AVFoundation
import Accelerate
import os.log

// MARK: - Private Helpers

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}

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
public class LoopAudioEngine {

    // MARK: - Callbacks

    /// Called when the engine state changes.
    public var onStateChange: ((EngineState) -> Void)?

    /// Called when a non-fatal or fatal error occurs.
    public var onError: ((LoopEngineError) -> Void)?

    /// Called when the audio route changes (e.g. headphones unplugged).
    /// The string is one of: "headphonesUnplugged", "categoryChange".
    public var onRouteChange: ((String) -> Void)?

    /// Called when BPM detection completes after a load.
    /// Always dispatched to `DispatchQueue.main`.
    public var onBpmDetected: ((BpmResult) -> Void)?

    /// Called with (rms, peak) amplitude in [0, 1] approximately 20 times per second
    /// while the engine is playing. Always dispatched to `DispatchQueue.main`.
    public var onAmplitude: ((Float, Float) -> Void)?

    /// Called when a seek operation completes; the argument is the final position in seconds.
    public var onSeekComplete: ((TimeInterval) -> Void)?

    /// Called when an audio interruption begins or ends.
    /// Arguments: interruptionType ("began"/"ended"), shouldResume flag.
    public var onInterruption: ((String, Bool) -> Void)?

    /// Called with 256 normalised [0,1] FFT magnitude bins when spectrum is enabled.
    public var onSpectrum: (([Float]) -> Void)?

    // MARK: - Private: Engine Infrastructure

    private let engine = AVAudioEngine()
    private let nodeA = AVAudioPlayerNode()
    private let nodeB = AVAudioPlayerNode()   // only connected when crossfadeDuration > 0
    private let mixerNode = AVAudioMixerNode()
    private let timePitchNode = AVAudioUnitTimePitch()
    private let eqNode = AVAudioUnitEQ(numberOfBands: 4)  // bands 0-2: EQ, band 3: cutoff filter
    private let reverbNode = AVAudioUnitReverb()
    private var compressorNode: AVAudioUnitEffect?

    // MARK: - Private: FFT

    private var fftSetup: vDSP_DFT_Setup?
    private var spectrumEnabled = false
    private static let fftSize = 512

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
    /// Must only be accessed from the main thread (matches all call sites in FlutterGaplessLoopPlugin).
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

    /// Guards the one-time AVAudioSession setCategory/setActive call across all engine instances.
    /// Shared AVAudioSession must only be configured once — reconfiguring while another engine is
    /// running can trigger AVAudioEngineConfigurationChange and invalidate in-flight engines.
    internal static var sessionConfigured = false

    // MARK: - Private: Amplitude Tap

    /// Whether an AVAudioEngine tap is currently installed on the main mixer output.
    private var _tapInstalled = false

    /// Timestamp of the last amplitude event dispatch. Used to throttle to ~20 Hz.
    private var _lastAmplitudeTime: TimeInterval = 0

    // MARK: - Public: Computed Properties

    /// The total duration of the loaded audio file in seconds. Returns 0 if no file is loaded.
    public var duration: TimeInterval { _fileDuration }

    /// The current playback position in seconds within the loop region.
    public var currentTime: TimeInterval {
        // Read on audioQueue to avoid data races on loopBuffer/originalBuffer/loopStart.
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

    public init() {
        // Session is configured lazily at first loadFile() call.
    }

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
        setState(.loading)  // keep this off-queue for immediate feedback

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
        applyMicroFade(to: buffer)  // pure computation on local buffer — off-queue is fine

        let computedDuration = Double(file.length) / format.sampleRate

        // Configure AVAudioSession once before entering the queue (safe off-queue).
        if !isGraphConfigured {
            do { try configureAudioSession() } catch {
                setState(.error)
                throw LoopEngineError.engineStartFailed(underlying: error)
            }
        }

        // Phase 2: Commit all state changes on the serial queue to prevent data races.
        var engineStartError: Error? = nil
        audioQueue.sync { [weak self] in
            guard let self else { return }
            self.nodeA.stop()  // stop any in-flight playback before swapping buffers
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
    ///
    /// In Mode A (default), this calls `scheduleBuffer(_:at:options: .loops)` on nodeA.
    /// AVAudioEngine handles the loop at the hardware render level — no callbacks,
    /// no scheduling gaps, no drift.
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
    ///
    /// Extracts a sub-buffer for the region, applies micro-fade and zero-crossing
    /// alignment, then schedules it with `.loops`. Transitions to Mode B or D.
    ///
    /// - Parameters:
    ///   - start: Loop region start in seconds (>= 0).
    ///   - end: Loop region end in seconds (> start, <= file duration).
    /// - Throws: `LoopEngineError.invalidLoopRegion` if parameters are out of range.
    public func setLoopRegion(start: TimeInterval, end: TimeInterval) throws {
        // Capture on the queue to avoid races on originalBuffer and _fileDuration.
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

        // Buffer extraction is safe off-queue: `original` is now a local strong ref.
        let subBuffer = try extractSubBuffer(from: original, start: start, end: end)
        applyMicroFade(to: subBuffer)
        alignToZeroCrossings(buffer: subBuffer)

        // Commit state changes on the queue.
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
    ///
    /// Values > 0 activate the dual-node crossfade system (Mode C or D).
    /// nodeB is attached and connected lazily when crossfade is first enabled.
    ///
    /// - Parameter duration: Crossfade duration in seconds. Clamped to 50% of loop region.
    public func setCrossfadeDuration(_ duration: TimeInterval) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.crossfadeDuration = duration

            if duration > 0 {
                // Attach nodeB to the engine graph if not already done.
                if !self.nodeBIsConnected, let format = self.originalBuffer?.format {
                    self.engine.attach(self.nodeB)
                    self.engine.connect(self.nodeB, to: self.mixerNode, format: format)
                    self.nodeBIsConnected = true
                    self.logger.info("nodeB attached for crossfade")
                }

                // Determine the active buffer's duration to clamp crossfade.
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
    ///
    /// Delegates to `AVAudioMixerNode.pan`, which applies an equal-power curve
    /// internally. Safe to call before the first load. Persists across loads —
    /// `mixerNode` retains its property values regardless of engine state.
    public func setPan(_ pan: Float) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.mixerNode.pan = max(-1.0, min(1.0, pan))
        }
    }

    /// Sets the playback rate (speed) while preserving pitch.
    ///
    /// [rate] is a multiplier: 1.0 = normal, 2.0 = double speed, 0.5 = half speed.
    /// Uses `AVAudioUnitTimePitch.rate` for pitch-independent time stretching.
    /// Persists across loads — `timePitchNode` is never torn down between loads.
    public func setPlaybackRate(_ rate: Float) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.timePitchNode.rate = max(0.03125, min(32.0, rate))
        }
    }

    /// Seeks to a position within the loaded file.
    ///
    /// In Modes A and B, seeking stops nodeA, plays the remaining frames of the
    /// current playthrough from the seek position, then resumes looping from
    /// loopStart on the next iteration.
    ///
    /// - Parameter time: Target position in seconds.
    /// - Throws: `LoopEngineError.seekOutOfBounds` if time is outside file duration.
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

            // Schedule the remaining frames from seekPosition to loopEnd as a one-shot,
            // then queue the full loop buffer with .loops for subsequent iterations.
            let effectiveEnd = self.loopBuffer != nil ? self.loopEnd : self._fileDuration
            if let remaining = try? self.extractSubBuffer(from: buf, start: time, end: effectiveEnd) {
                // Schedule remaining frames once (no loop), then re-arm the loop.
                self.nodeA.scheduleBuffer(remaining, at: nil, options: []) { [weak self] in
                    guard let self else { return }
                    self.audioQueue.async {
                        // After the one-shot completes, re-arm the full loop buffer.
                        self.nodeA.scheduleBuffer(buf, at: nil, options: .loops, completionHandler: nil)
                    }
                }
            } else {
                // Fallback: if extraction fails (seek near end), just reschedule normally.
                self.scheduleForCurrentMode()
            }

            if wasPlaying { self.nodeA.play() }
            self.logger.info("seek: \(time)s")
            let seekPos = time
            DispatchQueue.main.async { [weak self] in
                self?.onSeekComplete?(seekPos)
            }
        }
    }

    // MARK: - Public API: New Tier 1-3 Methods

    /// Sets pitch offset in semitones (±24), independent of playback rate.
    public func setPitch(_ semitones: Float) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.timePitchNode.pitch = (semitones * 100).clamped(to: -2400...2400)
        }
    }

    /// Schedules playback to start at a specific AVAudioTime (for sample-accurate sync).
    public func playAtTime(_ time: AVAudioTime) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            guard self._state == .ready || self._state == .stopped else { return }
            self.scheduleForCurrentMode()
            self.nodeA.play(at: time)
            self.setState(.playing)
            self.installAmplitudeTap()
        }
    }

    /// Fades volume to [targetVolume] over [durationMs] milliseconds at 100 Hz.
    public func fadeTo(targetVolume: Float, durationMs: Int) {
        let steps = max(1, durationMs / 10)
        let stepInterval = Double(durationMs) / 1000.0 / Double(steps)
        let startVolume = mixerNode.outputVolume
        let delta = targetVolume - startVolume
        var step = 0
        Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            step += 1
            let progress = Float(step) / Float(steps)
            self.audioQueue.async {
                self.mixerNode.outputVolume = startVolume + delta * progress
            }
            if step >= steps { timer.invalidate() }
        }
    }

    /// Returns a downsampled peak array for waveform display.
    public func getWaveformData(numSamples: Int) -> [Float] {
        guard let buf = originalBuffer else { return [] }
        guard let channelData = buf.floatChannelData else { return [] }
        let ch0 = channelData[0]
        let frameCount = Int(buf.frameLength)
        let blockSize = max(1, frameCount / numSamples)
        var result = [Float]()
        result.reserveCapacity(numSamples)
        var i = 0
        while i < frameCount && result.count < numSamples {
            var peak: Float = 0
            let end = min(i + blockSize, frameCount)
            for j in i..<end { peak = max(peak, abs(ch0[j])) }
            result.append(peak)
            i = end
        }
        return result
    }

    /// Detects silence regions in the loaded file.
    public func detectSilenceRegions(threshold: Float, minDuration: Double) -> [[String: Double]] {
        guard let buf = originalBuffer else { return [] }
        guard let channelData = buf.floatChannelData else { return [] }
        let ch0 = channelData[0]
        let frameCount = Int(buf.frameLength)
        let sr = buf.format.sampleRate
        let minFrames = Int(minDuration * sr)
        var regions = [[String: Double]]()
        var silenceStart: Int? = nil
        var i = 0
        while i < frameCount {
            let sample = abs(ch0[i])
            if sample < threshold {
                if silenceStart == nil { silenceStart = i }
            } else {
                if let start = silenceStart {
                    let len = i - start
                    if len >= minFrames {
                        regions.append(["start": Double(start) / sr, "end": Double(i) / sr])
                    }
                    silenceStart = nil
                }
            }
            i += 1
        }
        if let start = silenceStart {
            let len = frameCount - start
            if len >= minFrames {
                regions.append(["start": Double(start) / sr, "end": Double(frameCount) / sr])
            }
        }
        return regions
    }

    /// Trims leading/trailing silence by applying a loop region.
    public func trimSilence(threshold: Float, minDuration: Double) {
        guard let buf = originalBuffer else { return }
        guard let channelData = buf.floatChannelData else { return }
        let ch0 = channelData[0]
        let frameCount = Int(buf.frameLength)
        let sr = buf.format.sampleRate
        var firstNonSilent = 0
        var lastNonSilent = frameCount - 1
        for i in 0..<frameCount {
            if abs(ch0[i]) >= threshold { firstNonSilent = i; break }
        }
        for i in stride(from: frameCount - 1, through: 0, by: -1) {
            if abs(ch0[i]) >= threshold { lastNonSilent = i; break }
        }
        let startSecs = Double(firstNonSilent) / sr
        let endSecs   = Double(lastNonSilent + 1) / sr
        if startSecs < endSecs {
            try? setLoopRegion(start: startSecs, end: endSecs)
        }
    }

    /// Computes integrated LUFS (EBU R128 simplified, K-weighted).
    public func getLoudness() -> Double {
        guard let buf = originalBuffer else { return -70.0 }
        guard let channelData = buf.floatChannelData else { return -70.0 }
        let frameCount = Int(buf.frameLength)
        guard frameCount > 0 else { return -70.0 }
        let ch0 = channelData[0]
        var sumSquare: Double = 0.0
        var prev: Float = 0
        for i in 0..<frameCount {
            let s = ch0[i]
            let hpOut = s - prev * 0.9
            prev = s
            sumSquare += Double(hpOut * hpOut)
        }
        let meanSquare = sumSquare / Double(frameCount)
        if meanSquare <= 0 { return -70.0 }
        return -0.691 + 10.0 * log10(meanSquare)
    }

    /// Adjusts volume to reach targetLufs based on measured loudness.
    public func normaliseLoudness(targetLufs: Double) {
        let measured = getLoudness()
        let gainDb = targetLufs - measured
        let linearGain = Float(pow(10.0, gainDb / 20.0))
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.mixerNode.outputVolume = (self.mixerNode.outputVolume * linearGain).clamped(to: 0...1)
        }
    }

    // MARK: - Public API: EQ

    /// Sets the 3-band EQ gains in dB (low shelf 80Hz, peak 1kHz, high shelf 10kHz).
    public func setEq(low: Float, mid: Float, high: Float) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.eqNode.bands[0].gain    = low.clamped(to: -12...12)
            self.eqNode.bands[1].gain    = mid.clamped(to: -12...12)
            self.eqNode.bands[2].gain    = high.clamped(to: -12...12)
            self.eqNode.bands[0].bypass  = (low  == 0)
            self.eqNode.bands[1].bypass  = (mid  == 0)
            self.eqNode.bands[2].bypass  = (high == 0)
        }
    }

    /// Resets all EQ bands to 0 dB (bypassed).
    public func resetEq() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            // Only reset bands 0-2 (EQ bands); leave band 3 (cutoff) untouched
            for i in 0..<3 { self.eqNode.bands[i].gain = 0; self.eqNode.bands[i].bypass = true }
        }
    }

    // MARK: - Public API: Cutoff Filter

    /// Applies a low-pass or high-pass cutoff filter using EQ band 3.
    ///
    /// - Parameters:
    ///   - cutoffHz:  Corner frequency in Hz (20–20000).
    ///   - type:      0 = low-pass, 1 = high-pass.
    ///   - resonance: Q factor (0.1–10.0). Maps to bandwidth: bandwidth = 1/(Q * ln(2)).
    public func setCutoffFilter(cutoffHz: Float, type: Int, resonance: Float) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            let band = self.eqNode.bands[3]
            band.filterType = (type == 1) ? .highPass : .lowPass
            band.frequency  = cutoffHz.clamped(to: 20...20000)
            // AVAudioUnitEQ bandwidth is in octaves. Convert Q to octaves:
            // bandwidth_octaves = 2 / ln(2) * asinh(1 / (2*Q))  ≈ 1/Q for Q > 0.5
            // Simpler: use 0.5 as a starting point and clamp to valid range [0.05, 5.0]
            let q = resonance.clamped(to: 0.1...10.0)
            band.bandwidth  = (1.0 / q).clamped(to: 0.05...5.0)
            band.bypass     = false
        }
    }

    /// Disables the cutoff filter (bypasses band 3).
    public func resetCutoffFilter() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.eqNode.bands[3].bypass = true
        }
    }

    // MARK: - Public API: Reverb

    private static let reverbPresets: [AVAudioUnitReverbPreset] = [
        .smallRoom, .mediumRoom, .largeRoom, .mediumHall, .largeHall, .plate, .cathedral
    ]

    /// Sets the reverb preset and wet/dry mix.
    public func setReverb(presetIndex: Int, wetMix: Float) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            let idx = presetIndex % LoopAudioEngine.reverbPresets.count
            self.reverbNode.loadFactoryPreset(LoopAudioEngine.reverbPresets[idx])
            self.reverbNode.wetDryMix = (wetMix * 100).clamped(to: 0...100)
            self.reverbNode.bypass = false
        }
    }

    /// Disables reverb (bypasses the node).
    public func disableReverb() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.reverbNode.bypass = true
        }
    }

    // MARK: - Public API: Compressor

    /// Sets compressor parameters using kAudioUnitSubType_DynamicsProcessor.
    public func setCompressor(threshold: Float, makeupGain: Float, attackMs: Float, releaseMs: Float) {
        guard let node = compressorNode else { return }
        audioQueue.async {
            let au = node.audioUnit
            AudioUnitSetParameter(au, kDynamicsProcessorParam_Threshold,
                                  kAudioUnitScope_Global, 0, threshold, 0)
            AudioUnitSetParameter(au, kDynamicsProcessorParam_OverallGain,
                                  kAudioUnitScope_Global, 0, makeupGain, 0)
            AudioUnitSetParameter(au, kDynamicsProcessorParam_AttackTime,
                                  kAudioUnitScope_Global, 0, attackMs / 1000.0, 0)
            AudioUnitSetParameter(au, kDynamicsProcessorParam_ReleaseTime,
                                  kAudioUnitScope_Global, 0, releaseMs / 1000.0, 0)
            node.bypass = false
        }
    }

    /// Disables the compressor (bypasses the node).
    public func disableCompressor() {
        guard let node = compressorNode else { return }
        audioQueue.async { node.bypass = true }
    }

    // MARK: - Public API: FFT Spectrum

    /// Starts emitting real-time FFT data via onSpectrum.
    public func enableSpectrum() {
        fftSetup = vDSP_DFT_zrop_CreateSetup(nil, UInt(LoopAudioEngine.fftSize), .FORWARD)
        spectrumEnabled = true
    }

    /// Stops FFT spectrum emission.
    public func disableSpectrum() {
        spectrumEnabled = false
        if let setup = fftSetup { vDSP_DFT_DestroySetup(setup) }
        fftSetup = nil
    }

    // MARK: - Public API: WAV Export

    /// Exports a region of the loaded file to a WAV file.
    public func exportToFile(url: URL, format: Int, regionStart: Double?, regionEnd: Double?) throws {
        guard let buf = originalBuffer else { throw LoopEngineError.bufferReadFailed }
        let sr = buf.format.sampleRate
        let totalSecs = Double(buf.frameLength) / sr
        let startFrame = AVAudioFramePosition(((regionStart ?? 0) * sr).rounded())
        let endFrame   = AVAudioFramePosition(((regionEnd ?? totalSecs) * sr).rounded())
        let frameCount = AVAudioFrameCount(max(0, endFrame - startFrame))
        guard frameCount > 0 else { throw LoopEngineError.bufferReadFailed }

        let outputSettings: [String: Any]
        if format == 0 {
            outputSettings = [
                AVFormatIDKey:             Int(kAudioFormatLinearPCM),
                AVSampleRateKey:           sr,
                AVNumberOfChannelsKey:     buf.format.channelCount,
                AVLinearPCMBitDepthKey:    32,
                AVLinearPCMIsFloatKey:     true,
                AVLinearPCMIsBigEndianKey: false,
            ]
        } else {
            outputSettings = [
                AVFormatIDKey:             Int(kAudioFormatLinearPCM),
                AVSampleRateKey:           sr,
                AVNumberOfChannelsKey:     buf.format.channelCount,
                AVLinearPCMBitDepthKey:    16,
                AVLinearPCMIsFloatKey:     false,
                AVLinearPCMIsBigEndianKey: false,
            ]
        }
        let outFile = try AVAudioFile(forWriting: url, settings: outputSettings)
        if let subBuf = AVAudioPCMBuffer(pcmFormat: buf.format, frameCapacity: frameCount),
           let srcData = buf.floatChannelData,
           let dstData = subBuf.floatChannelData {
            subBuf.frameLength = frameCount
            for ch in 0..<Int(buf.format.channelCount) {
                memcpy(dstData[ch],
                       srcData[ch].advanced(by: Int(startFrame)),
                       Int(frameCount) * MemoryLayout<Float>.stride)
            }
            try outFile.write(from: subBuf)
        }
    }

    /// Releases all native resources. The engine cannot be used after this call.
    public func dispose() {
        bpmWorkItem?.cancel()
        bpmWorkItem = nil
        disableSpectrum()
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

    /// Builds the audio graph: nodeA → mixerNode → eqNode → reverbNode → compressorNode → timePitchNode → mainMixerNode → outputNode.
    /// nodeB is only attached when crossfade is enabled (lazy).
    private func setupEngineGraph(format: AVAudioFormat) {
        // Configure EQ bands: low-shelf 80Hz, peak 1kHz, high-shelf 10kHz, cutoff (bypassed)
        eqNode.bands[0].filterType  = .lowShelf
        eqNode.bands[0].frequency   = 80
        eqNode.bands[0].bypass      = true
        eqNode.bands[1].filterType  = .parametric
        eqNode.bands[1].frequency   = 1000
        eqNode.bands[1].bandwidth   = 1.0
        eqNode.bands[1].bypass      = true
        eqNode.bands[2].filterType  = .highShelf
        eqNode.bands[2].frequency   = 10000
        eqNode.bands[2].bypass      = true
        // Band 3: cutoff filter (low-pass by default, bypassed until setCutoffFilter is called)
        eqNode.bands[3].filterType  = .lowPass
        eqNode.bands[3].frequency   = 20000
        eqNode.bands[3].bandwidth   = 0.5   // Q ≈ 1/bandwidth; 0.5 octaves → Q ≈ 0.707
        eqNode.bands[3].bypass      = true

        reverbNode.bypass = true

        // Set up compressor node
        let compDesc = AudioComponentDescription(
            componentType:         kAudioUnitType_Effect,
            componentSubType:      kAudioUnitSubType_DynamicsProcessor,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags:        0,
            componentFlagsMask:    0)
        let comp = AVAudioUnitEffect(audioComponentDescription: compDesc)
        compressorNode = comp
        comp.bypass = true

        engine.attach(nodeA)
        engine.attach(mixerNode)
        engine.attach(eqNode)
        engine.attach(reverbNode)
        engine.attach(comp)
        engine.attach(timePitchNode)

        engine.connect(nodeA,        to: mixerNode,    format: format)
        engine.connect(mixerNode,    to: eqNode,       format: format)
        engine.connect(eqNode,       to: reverbNode,   format: format)
        engine.connect(reverbNode,   to: comp,         format: format)
        engine.connect(comp,         to: timePitchNode, format: format)
        engine.connect(timePitchNode, to: engine.mainMixerNode, format: nil)
        logger.debug("Engine graph configured: nodeA → mixer → eq → reverb → comp → timePitch → mainMixer → output")
    }

    // MARK: - Private: Scheduling

    /// Selects and applies the correct scheduling strategy for the current mode.
    private func scheduleForCurrentMode() {
        switch playbackMode {
        case .modeA:
            // Mode A: Full buffer, no crossfade.
            // scheduleBuffer with .loops runs inside the hardware render thread.
            // The loop wrap happens within a single 256-frame render cycle (~5.8ms at 44100Hz).
            // This is physically impossible to produce an audible gap.
            guard let buf = originalBuffer else { return }
            nodeA.scheduleBuffer(buf, at: nil, options: .loops, completionHandler: nil)

        case .modeB:
            // Mode B: Sub-buffer, no crossfade.
            // Zero-crossing aligned sub-buffer scheduled with .loops.
            guard let buf = loopBuffer else { return }
            nodeA.scheduleBuffer(buf, at: nil, options: .loops, completionHandler: nil)

        case .modeC:
            // Mode C: Full buffer, crossfade enabled.
            guard let buf = originalBuffer else { return }
            scheduleCrossfade(buffer: buf)

        case .modeD:
            // Mode D: Sub-buffer, crossfade enabled.
            guard let buf = loopBuffer else { return }
            scheduleCrossfade(buffer: buf)
        }
    }

    /// Schedules dual-node crossfade playback for Modes C and D.
    ///
    /// Strategy: nodeA plays the full buffer with .loops for continuous output.
    /// nodeB plays a crossfade tail buffer timed to the loop boundary.
    /// Pre-computed equal-power ramps are applied at buffer-build time.
    private func scheduleCrossfade(buffer: AVAudioPCMBuffer) {
        guard let ramp = crossfadeRamp else {
            // No ramp available — fall back to simple .loops.
            nodeA.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
            return
        }

        let bufDuration = Double(buffer.frameLength) / buffer.format.sampleRate
        let crossfadeSecs = Double(ramp.frameCount) / buffer.format.sampleRate
        let tailStart = bufDuration - crossfadeSecs

        guard tailStart > 0,
              let tailBuffer = try? extractSubBuffer(from: buffer, start: tailStart, end: bufDuration),
              let headBuffer = try? extractSubBuffer(from: buffer, start: 0, end: crossfadeSecs) else {
            // Edge case: crossfade region doesn't fit — fall back to simple .loops.
            nodeA.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
            return
        }

        // Apply ramps to copies of the tail/head buffers.
        // CrossfadeEngine.apply modifies in-place — the source buffer is not touched.
        CrossfadeEngine.apply(ramp: ramp, primary: tailBuffer, secondary: headBuffer)

        // nodeA plays the full buffer continuously.
        nodeA.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)

        // nodeB plays the crossfade overlap at each loop boundary.
        // Use the completion handler on nodeA's loop-end to re-trigger nodeB.
        // Note: .loops mode does not call completionHandler, so we use a timed approach:
        // schedule the head buffer on nodeB with a delay equal to the loop duration minus
        // the crossfade duration, repeating via recursive scheduling.
        scheduleNodeBCrossfade(headBuffer: headBuffer, loopDuration: bufDuration, crossfadeSecs: crossfadeSecs)
    }

    /// Recursively schedules the crossfade tail on nodeB, timed to each loop boundary.
    private func scheduleNodeBCrossfade(headBuffer: AVAudioPCMBuffer, loopDuration: Double, crossfadeSecs: Double) {
        guard nodeBIsConnected, crossfadeDuration > 0 else { return }

        // Determine when to start the next crossfade on nodeB.
        // We want nodeB to begin playing crossfadeSecs before the loop wraps.
        // Compute the absolute sample time using nodeA's timeline.
        guard let lastRender = nodeA.lastRenderTime,
              let playerTime = nodeA.playerTime(forNodeTime: lastRender) else {
            // nodeA hasn't started yet — schedule buffer before calling play().
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
        let currentSample = max(0, rawSample)  // sampleTime can be negative before first render
        let loopFrames = Int64(loopDuration * sampleRate)
        let crossfadeFrames = Int64(crossfadeSecs * sampleRate)

        // Frames remaining until end of current loop iteration.
        let positionInLoop = currentSample % loopFrames
        let framesUntilBoundary = loopFrames - positionInLoop

        // Start crossfade crossfadeFrames before the boundary.
        let framesUntilCrossfadeStart = framesUntilBoundary - crossfadeFrames
        let startSample = currentSample + max(0, framesUntilCrossfadeStart)
        let startTime = AVAudioTime(sampleTime: startSample, atRate: sampleRate)

        if !nodeB.isPlaying { nodeB.play() }

        nodeB.scheduleBuffer(headBuffer, at: startTime, options: []) { [weak self] in
            guard let self else { return }
            self.audioQueue.async {
                // Reschedule for the next loop boundary.
                self.scheduleNodeBCrossfade(
                    headBuffer: headBuffer,
                    loopDuration: loopDuration,
                    crossfadeSecs: crossfadeSecs
                )
            }
        }
    }

    // MARK: - Private: Buffer Processing

    /// Applies a 5ms linear micro-fade to the head and tail of the buffer in-place.
    ///
    /// This prevents clicks at the loop boundary caused by sample discontinuities.
    /// 5ms at 44100Hz = 220 frames — below human auditory click detection threshold
    /// for musical content. Applied once at load time; zero runtime cost.
    private func applyMicroFade(to buffer: AVAudioPCMBuffer) {
        let format = buffer.format
        let channelCount = Int(format.channelCount)
        let totalFrames = Int(buffer.frameLength)
        // Clamp to half the buffer to avoid fade-in and fade-out overlapping.
        let fadeLengthFrames = min(Int(format.sampleRate * 0.005), totalFrames / 2)

        guard fadeLengthFrames > 0, let channelData = buffer.floatChannelData else { return }

        for ch in 0..<channelCount {
            let data = channelData[ch]
            // Linear fade-in: multiply frame[i] by (i / fadeLengthFrames).
            for i in 0..<fadeLengthFrames {
                let gain = Float(i) / Float(fadeLengthFrames)
                data[i] *= gain
            }
            // Linear fade-out: multiply from the tail inward.
            for i in 0..<fadeLengthFrames {
                let gain = Float(i) / Float(fadeLengthFrames)
                data[totalFrames - 1 - i] *= gain
            }
        }
    }

    /// Scans ±10ms at the buffer boundaries for zero-crossings and zeros out
    /// pre-boundary samples to reduce discontinuity energy.
    private func alignToZeroCrossings(buffer: AVAudioPCMBuffer) {
        let sampleRate = buffer.format.sampleRate
        let windowFrames = Int(sampleRate * 0.010)   // 10ms window
        let totalFrames = Int(buffer.frameLength)
        guard totalFrames > 0, let data = buffer.floatChannelData else { return }
        let ch0 = data[0]

        // Find the first upward zero-crossing (negative → positive) near the start.
        var fadeStart = 0
        for i in 1..<min(windowFrames, totalFrames) {
            if ch0[i - 1] <= 0 && ch0[i] >= 0 {
                fadeStart = i
                break
            }
        }

        // Find the last downward zero-crossing (positive → negative) near the end.
        var fadeEnd = totalFrames
        for i in stride(from: totalFrames - 1, through: max(totalFrames - windowFrames, 1), by: -1) {
            if ch0[i] <= 0 && ch0[i - 1] >= 0 {
                fadeEnd = i
                break
            }
        }

        // Zero out samples before the first zero-crossing and after the last.
        // If no zero-crossing was found (fadeStart == 0, fadeEnd == totalFrames),
        // this is a no-op — the micro-fade already handles the boundary.
        let channelCount = Int(buffer.format.channelCount)
        for ch in 0..<channelCount {
            let d = data[ch]
            for i in 0..<fadeStart { d[i] = 0 }
            for i in fadeEnd..<totalFrames { d[i] = 0 }
        }
    }

    /// Extracts a sub-buffer from [start, end) seconds using direct pointer arithmetic.
    ///
    /// O(n) in frame count, O(1) allocation — no intermediate copies.
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
            // Advance the source channel pointer by startFrame floats.
            let src = srcData[ch].advanced(by: Int(startFrame))
            let dst = dstData[ch]
            // Direct memory copy — no intermediate allocation.
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

    // MARK: - Private: Audio Session

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()

        // setCategory/setActive run once across all engine instances.
        // Calling them while another AVAudioEngine is running can trigger
        // AVAudioEngineConfigurationChange, which invalidates all in-flight engines.
        if !LoopAudioEngine.sessionConfigured {
            LoopAudioEngine.sessionConfigured = true
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: session
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: session
        )
        logger.info("AVAudioSession configured: category=playback")
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        audioQueue.async { [weak self] in
            guard let self else { return }
            switch type {
            case .began:
                // Phone call, Siri, etc. — pause silently.
                if self._state == .playing {
                    self.nodeA.pause()
                    if self.nodeBIsConnected { self.nodeB.pause() }
                    self.setState(.paused)
                    self.logger.info("Interruption began: paused")
                }
                DispatchQueue.main.async { [weak self] in
                    self?.onInterruption?("began", false)
                }
            case .ended:
                let optValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let opts = AVAudioSession.InterruptionOptions(rawValue: optValue)
                let shouldResume = opts.contains(.shouldResume)
                // Resume only if the system signals it is safe to do so.
                if shouldResume && self._state == .paused {
                    do {
                        try self.engine.start()
                        self.nodeA.play()
                        if self.nodeBIsConnected { self.nodeB.play() }
                        self.setState(.playing)
                        self.logger.info("Interruption ended: resumed")
                    } catch {
                        self.logger.error("Failed to restart engine after interruption: \(error.localizedDescription)")
                        self.setState(.error)
                    }
                }
                DispatchQueue.main.async { [weak self] in
                    self?.onInterruption?("ended", shouldResume)
                }
            @unknown default:
                break
            }
        }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        guard let info = notification.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        audioQueue.async { [weak self] in
            guard let self else { return }
            switch reason {
            case .oldDeviceUnavailable:
                // Headphones unplugged — pause to avoid jarring speaker playback.
                if self._state == .playing {
                    self.nodeA.pause()
                    if self.nodeBIsConnected { self.nodeB.pause() }
                    self.setState(.paused)
                }
                DispatchQueue.main.async { [weak self] in
                    self?.onRouteChange?("headphonesUnplugged")
                }
                self.logger.info("Route change: headphones unplugged")
            case .categoryChange:
                DispatchQueue.main.async { [weak self] in
                    self?.onRouteChange?("categoryChange")
                }
                self.logger.info("Route change: category changed")
            default:
                break
            }
        }
    }

    // MARK: - Private: Amplitude Tap

    /// Installs a tap on the main mixer output node to measure RMS and peak amplitude.
    ///
    /// The tap fires every ~23 ms (1024 frames at 44100 Hz). Events are throttled
    /// to ~20 Hz (every 50 ms) to keep the event channel lightweight.
    /// Must be called from `audioQueue` or before `engine.start()`.
    private func installAmplitudeTap() {
        guard !_tapInstalled else { return }
        _tapInstalled = true
        _lastAmplitudeTime = 0

        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self else { return }

            // Throttle to ~20 Hz
            let now = Date.timeIntervalSinceReferenceDate
            guard now - self._lastAmplitudeTime >= 0.05 else { return }
            self._lastAmplitudeTime = now

            // Compute RMS and peak across all channels and frames.
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

            if let onAmplitude = self.onAmplitude {
                DispatchQueue.main.async {
                    onAmplitude(min(rms, 1.0), min(peak, 1.0))
                }
            }

            // FFT spectrum
            if self.spectrumEnabled, let setup = self.fftSetup, let onSpectrum = self.onSpectrum {
                let fftSize = LoopAudioEngine.fftSize
                let ch0 = channelData[0]
                let samples = min(frameCount, fftSize)
                var realIn  = [Float](repeating: 0, count: fftSize)
                var imagIn  = [Float](repeating: 0, count: fftSize)
                var realOut = [Float](repeating: 0, count: fftSize / 2)
                var imagOut = [Float](repeating: 0, count: fftSize / 2)

                // Apply Hann window
                for i in 0..<samples {
                    let w = 0.5 * (1 - cos(2 * .pi * Float(i) / Float(fftSize - 1)))
                    realIn[i] = ch0[i] * w
                }
                vDSP_DFT_Execute(setup, &realIn, &imagIn, &realOut, &imagOut)

                // Magnitude and normalise
                var mags = [Float](repeating: 0, count: fftSize / 2)
                for i in 0..<(fftSize / 2) {
                    let re = realOut[i], im = imagOut[i]
                    mags[i] = sqrt(re * re + im * im) / Float(fftSize / 2)
                }
                // Normalise to [0,1]
                var maxMag: Float = 1e-6
                vDSP_maxv(&mags, 1, &maxMag, vDSP_Length(fftSize / 2))
                if maxMag > 0 { var d = maxMag; vDSP_vsdiv(&mags, 1, &d, &mags, 1, vDSP_Length(fftSize / 2)) }

                DispatchQueue.main.async { onSpectrum(mags) }
            }
        }
        logger.debug("Amplitude tap installed")
    }

    /// Removes the tap from the main mixer output node.
    private func removeAmplitudeTap() {
        guard _tapInstalled else { return }
        _tapInstalled = false
        engine.mainMixerNode.removeTap(onBus: 0)
        logger.debug("Amplitude tap removed")
    }

    // MARK: - Private: BPM Detection

    /// Launches BPM detection for `buffer` on a utility-priority background thread.
    /// On completion, dispatches `onBpmDetected` to the main queue.
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

#else

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

#endif // os(iOS)
