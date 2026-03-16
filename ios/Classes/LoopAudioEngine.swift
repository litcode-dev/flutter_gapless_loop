#if os(iOS)
import AVFoundation
import AudioToolbox
import Accelerate
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

    /// Called when a system audio interruption begins or ends.
    /// Argument is `"began"` or `"ended"`. Always dispatched to `DispatchQueue.main`.
    public var onInterruption: ((String) -> Void)?

    /// Called after a seek operation completes and the buffer has been rescheduled.
    /// Argument is the actual seek position in seconds. Dispatched to `DispatchQueue.main`.
    public var onSeekComplete: ((TimeInterval) -> Void)?

    /// Called with 256 normalised-magnitude FFT bins ~10 Hz while playing.
    /// Arguments are (magnitudes, sampleRate). Always dispatched to `DispatchQueue.main`.
    public var onSpectrum: (([Float], Double) -> Void)?

    // MARK: - Private: Engine Infrastructure

    private let engine = AVAudioEngine()
    private let nodeA = AVAudioPlayerNode()
    private let nodeB = AVAudioPlayerNode()   // only connected when crossfadeDuration > 0
    private let mixerNode = AVAudioMixerNode()
    private let timePitchNode = AVAudioUnitTimePitch()

    // Tier 3 effect nodes — always in the graph, bypassed by default
    private let eqNode: AVAudioUnitEQ = {
        let eq = AVAudioUnitEQ(numberOfBands: 3)
        // Band 0: 80 Hz low shelf
        eq.bands[0].filterType  = .lowShelf
        eq.bands[0].frequency   = 80
        eq.bands[0].gain        = 0
        eq.bands[0].bypass      = false
        // Band 1: 1 kHz parametric peak
        eq.bands[1].filterType  = .parametric
        eq.bands[1].frequency   = 1000
        eq.bands[1].bandwidth   = 1.0
        eq.bands[1].gain        = 0
        eq.bands[1].bypass      = false
        // Band 2: 10 kHz high shelf
        eq.bands[2].filterType  = .highShelf
        eq.bands[2].frequency   = 10000
        eq.bands[2].gain        = 0
        eq.bands[2].bypass      = false
        return eq
    }()

    private let reverbNode: AVAudioUnitReverb = {
        let r = AVAudioUnitReverb()
        r.wetDryMix = 0    // fully dry by default
        return r
    }()

    private let compressorNode: AVAudioUnitEffect = {
        var desc = AudioComponentDescription()
        desc.componentType         = kAudioUnitType_Effect
        desc.componentSubType      = kAudioUnitSubType_DynamicsProcessor
        desc.componentManufacturer = kAudioUnitManufacturer_Apple
        desc.componentFlags        = 0
        desc.componentFlagsMask    = 0
        let fx = AVAudioUnitEffect(audioComponentDescription: desc)
        fx.bypass = true   // bypassed until explicitly enabled
        return fx
    }()

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

    // MARK: - Private: Amplitude Tap

    /// Whether an AVAudioEngine tap is currently installed on the main mixer output.
    private var _tapInstalled = false

    /// Timestamp of the last amplitude event dispatch. Used to throttle to ~20 Hz.
    private var _lastAmplitudeTime: TimeInterval = 0

    /// Timestamp of the last spectrum event dispatch. Throttled to ~10 Hz.
    private var _lastSpectrumTime: TimeInterval = 0

    /// Pre-allocated vDSP FFT setup for 1024-point real FFT. Lazy.
    private var _fftSetup: vDSP_DFT_SetupD?

    // Pre-allocated buffers for FFT computation (1024-point).
    private var _fftWindowedReal  = [Double](repeating: 0, count: 1024)
    private var _fftWindowedImag  = [Double](repeating: 0, count: 1024)
    private var _fftMagnitudes    = [Double](repeating: 0, count: 512)
    private var _hannWindow       = [Double](repeating: 0, count: 1024)

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

    /// Shifts the pitch by [semitones] without changing playback speed.
    ///
    /// `0.0` = no shift (default). Range: −24.0 to +24.0 semitones (±2 octaves).
    /// `AVAudioUnitTimePitch.pitch` is in cents (100 cents = 1 semitone), so the
    /// value is multiplied by 100 before being applied.
    ///
    /// This is fully independent of `setPlaybackRate` — both properties on
    /// `AVAudioUnitTimePitch` can be set simultaneously.
    public func setPitch(_ semitones: Float) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            // AVAudioUnitTimePitch.pitch range: −2400 to +2400 cents
            self.timePitchNode.pitch = max(-2400.0, min(2400.0, semitones * 100.0))
        }
    }

    /// Ramps the mixer volume from its current value to [targetVolume] over [duration].
    ///
    /// Uses a `DispatchSourceTimer` on `audioQueue` firing at ~100 Hz so the ramp
    /// is handled entirely off the Flutter thread.  Pass `startFromSilence: true`
    /// to immediately zero the volume before ramping up (fade-in).
    ///
    /// - Parameters:
    ///   - targetVolume:     Target volume in [0.0, 1.0].
    ///   - duration:         Total ramp duration.
    ///   - startFromSilence: If `true`, volume is zeroed before ramping to [targetVolume].
    public func fadeTo(targetVolume: Float, duration: TimeInterval, startFromSilence: Bool = false) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            if startFromSilence { self.mixerNode.outputVolume = 0.0 }
            let from = self.mixerNode.outputVolume
            let to   = max(0.0, min(1.0, targetVolume))
            guard duration > 0, abs(to - from) > 0.001 else {
                self.mixerNode.outputVolume = to
                return
            }
            self._startFadeTimer(from: from, to: to, duration: duration)
        }
    }

    // MARK: - Private: Fade Timer

    private var fadeTimer: DispatchSourceTimer?

    private func _startFadeTimer(from: Float, to: Float, duration: TimeInterval) {
        fadeTimer?.cancel()
        let stepHz:  Double = 100.0
        let stepSec: Double = 1.0 / stepHz
        let totalSteps = max(1, Int(duration * stepHz))
        var step = 0

        let timer = DispatchSource.makeTimerSource(queue: audioQueue)
        timer.schedule(deadline: .now() + stepSec, repeating: stepSec)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            step += 1
            let t = Float(step) / Float(totalSteps)
            let vol = from + (to - from) * min(t, 1.0)
            self.mixerNode.outputVolume = vol
            if step >= totalSteps {
                self.fadeTimer?.cancel()
                self.fadeTimer = nil
            }
        }
        fadeTimer = timer
        timer.resume()
    }

    // MARK: - Public: Waveform / Analysis

    /// Returns a downsampled peak-amplitude array with [resolution] data points.
    ///
    /// Each element is the maximum absolute sample in its segment, in `[0.0, 1.0]`.
    /// If no file is loaded an empty array is returned.
    ///
    /// - Parameter resolution: Number of output data points (clamped to `[2, 8192]`).
    public func getWaveformData(resolution: Int) -> [Float] {
        let r = max(2, min(8192, resolution))
        return audioQueue.sync { [weak self] -> [Float] in
            guard let self, let buf = self.originalBuffer,
                  let channelData = buf.floatChannelData else { return [] }
            let totalFrames  = Int(buf.frameLength)
            let channelCount = Int(buf.format.channelCount)
            guard totalFrames > 0 else { return [] }

            var peaks = [Float](repeating: 0, count: r)
            let segFrames = totalFrames / r

            for seg in 0..<r {
                let startFrame = seg * segFrames
                let endFrame   = seg == r - 1 ? totalFrames : startFrame + segFrames
                var peak: Float = 0
                for ch in 0..<channelCount {
                    let data = channelData[ch]
                    for i in startFrame..<endFrame {
                        let abs = fabsf(data[i])
                        if abs > peak { peak = abs }
                    }
                }
                peaks[seg] = min(peak, 1.0)
            }
            return peaks
        }
    }

    /// Scans the loaded file for silence below [thresholdDb] dBFS and returns
    /// the start and end of the non-silent region in seconds.
    ///
    /// If the entire file is silent, returns `(0.0, duration)`.
    ///
    /// - Parameter thresholdDb: Silence threshold in dBFS (e.g. `-60.0`). Must be negative.
    public func detectSilence(thresholdDb: Float) -> (start: TimeInterval, end: TimeInterval) {
        let threshold = pow(10.0, thresholdDb / 20.0) as Float
        return audioQueue.sync { [weak self] -> (TimeInterval, TimeInterval) in
            guard let self, let buf = self.originalBuffer,
                  let channelData = buf.floatChannelData else {
                return (0.0, self?._fileDuration ?? 0.0)
            }
            let totalFrames  = Int(buf.frameLength)
            let channelCount = Int(buf.format.channelCount)
            let sampleRate   = buf.format.sampleRate
            guard totalFrames > 0 else { return (0.0, self._fileDuration) }

            // Helper: checks if any channel at [frame] is above [threshold].
            func isAudible(_ frame: Int) -> Bool {
                for ch in 0..<channelCount {
                    if fabsf(channelData[ch][frame]) >= threshold { return true }
                }
                return false
            }

            // Scan from head for first audible frame.
            var startFrame = 0
            for i in 0..<totalFrames {
                if isAudible(i) { startFrame = i; break }
            }

            // Scan from tail for last audible frame.
            var endFrame = totalFrames - 1
            for i in stride(from: totalFrames - 1, through: 0, by: -1) {
                if isAudible(i) { endFrame = i; break }
            }

            let startSec = Double(startFrame) / sampleRate
            let endSec   = Double(endFrame + 1) / sampleRate
            return (startSec, endSec)
        }
    }

    /// Computes the integrated loudness of the loaded file in LUFS using
    /// EBU R128 / ITU-R BS.1770-4 K-weighting.
    ///
    /// Returns `-100.0` if no file is loaded or the file is silent.
    public func getLoudness() -> Double {
        return audioQueue.sync { [weak self] -> Double in
            guard let self, let buf = self.originalBuffer else { return -100.0 }
            return LoudnessAnalyser.analyse(buffer: buf)
        }
    }

    /// Starts playback at a future `AVAudioTime` derived from [hostTime].
    ///
    /// [hostTime] is a `mach_absolute_time()` unit value. The plugin computes
    /// this as `mach_absolute_time() + lookaheadMs_in_ticks` before calling
    /// this method, ensuring all players in a sync group start at the same time.
    public func syncPlay(hostTime: UInt64) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            guard self._state == .ready || self._state == .stopped else {
                self.logger.warning("syncPlay() ignored: state=\(self._state.rawValue)")
                return
            }
            self.scheduleForCurrentMode()
            let startTime = AVAudioTime(hostTime: hostTime)
            self.nodeA.play(at: startTime)
            self.setState(.playing)
            self.installAmplitudeTap()
            self.logger.info("syncPlay: hostTime=\(hostTime)")
        }
    }

    // MARK: - Public: EQ / Reverb / Compressor

    /// Sets the 3-band EQ gains in dB. Each value is clamped to ±12 dB.
    ///
    /// - Parameters:
    ///   - bassDb:   Low-shelf gain at 80 Hz.
    ///   - midDb:    Parametric peak gain at 1 kHz.
    ///   - trebleDb: High-shelf gain at 10 kHz.
    public func setEq(bassDb: Float, midDb: Float, trebleDb: Float) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.eqNode.bands[0].gain = max(-12, min(12, bassDb))
            self.eqNode.bands[1].gain = max(-12, min(12, midDb))
            self.eqNode.bands[2].gain = max(-12, min(12, trebleDb))
        }
    }

    /// Applies a factory reverb preset with a wet/dry mix in [0, 100] percent.
    ///
    /// Preset `none` or wetMix == 0 effectively bypasses the reverb node.
    public func setReverb(preset: String, wetMix: Float) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            let mix = max(0, min(100, wetMix * 100))

            if preset == "none" || mix == 0 {
                self.reverbNode.wetDryMix = 0
                return
            }

            let avPreset: AVAudioUnitReverbPreset = {
                switch preset {
                case "smallRoom":  return .smallRoom
                case "mediumRoom": return .mediumRoom
                case "largeRoom":  return .largeRoom
                case "mediumHall": return .mediumHall
                case "largeHall":  return .largeHall
                case "plate":      return .plate
                case "cathedral":  return .cathedral
                default:           return .mediumRoom
                }
            }()
            self.reverbNode.loadFactoryPreset(avPreset)
            self.reverbNode.wetDryMix = mix
        }
    }

    /// Configures the DynamicsProcessor compressor.
    ///
    /// - Parameters:
    ///   - enabled:      Pass `false` to bypass the compressor node.
    ///   - thresholdDb:  Compression threshold (−40 to 0 dB). Default −20.
    ///   - makeupGainDb: Makeup gain (−20 to +20 dB). Default 0.
    ///   - attackMs:     Attack time (1–200 ms). Default 10.
    ///   - releaseMs:    Release time (10–3000 ms). Default 100.
    public func setCompressor(
        enabled:      Bool,
        thresholdDb:  Float,
        makeupGainDb: Float,
        attackMs:     Float,
        releaseMs:    Float
    ) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.compressorNode.bypass = !enabled
            guard enabled else { return }
            let au = self.compressorNode.audioUnit
            AudioUnitSetParameter(au, kDynamicsProcessorParam_Threshold,
                                  kAudioUnitScope_Global, 0, thresholdDb, 0)
            AudioUnitSetParameter(au, kDynamicsProcessorParam_OverallGain,
                                  kAudioUnitScope_Global, 0, makeupGainDb, 0)
            AudioUnitSetParameter(au, kDynamicsProcessorParam_AttackTime,
                                  kAudioUnitScope_Global, 0, attackMs / 1000.0, 0)
            AudioUnitSetParameter(au, kDynamicsProcessorParam_ReleaseTime,
                                  kAudioUnitScope_Global, 0, releaseMs / 1000.0, 0)
        }
    }

    // MARK: - Public: Export

    /// Writes the current loop region (or full file if no region is set) as a
    /// 32-bit float WAV to [url].
    ///
    /// The export is the raw decoded PCM — effects are not rendered.
    /// Completion is called on `DispatchQueue.main`.
    public func exportToFile(url: URL, completion: @escaping (Error?) -> Void) {
        audioQueue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion(LoopEngineError.bufferReadFailed) }
                return
            }
            let buf = self.loopBuffer ?? self.originalBuffer
            guard let buffer = buf else {
                DispatchQueue.main.async { completion(LoopEngineError.bufferReadFailed) }
                return
            }
            DispatchQueue.global(qos: .utility).async {
                do {
                    let file = try AVAudioFile(
                        forWriting: url,
                        settings:   buffer.format.settings,
                        commonFormat: .pcmFormatFloat32,
                        interleaved: false)
                    try file.write(from: buffer)
                    DispatchQueue.main.async { completion(nil) }
                } catch {
                    DispatchQueue.main.async { completion(error) }
                }
            }
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
            let seekPosition = time
            DispatchQueue.main.async { [weak self] in
                self?.onSeekComplete?(seekPosition)
            }
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

    /// Builds the audio graph.
    ///
    /// Signal path:
    ///   nodeA → mixerNode → timePitchNode → eqNode → reverbNode → compressorNode → mainMixerNode → output
    ///
    /// nodeB is attached lazily when crossfade is first enabled.
    private func setupEngineGraph(format: AVAudioFormat) {
        engine.attach(nodeA)
        engine.attach(mixerNode)
        engine.connect(nodeA, to: mixerNode, format: format)
        engine.attach(timePitchNode)
        engine.connect(mixerNode, to: timePitchNode, format: format)
        // Tier 3 effect chain
        engine.attach(eqNode)
        engine.connect(timePitchNode, to: eqNode, format: nil)
        engine.attach(reverbNode)
        engine.connect(eqNode, to: reverbNode, format: nil)
        engine.attach(compressorNode)
        engine.connect(reverbNode, to: compressorNode, format: nil)
        engine.connect(compressorNode, to: engine.mainMixerNode, format: nil)
        logger.debug("Engine graph: nodeA→mixer→timePitch→EQ→reverb→compressor→mainMixer→output")
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
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)

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
                    self?.onInterruption?("began")
                }
            case .ended:
                // Resume only if the system signals it is safe to do so.
                if let optValue = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                    let opts = AVAudioSession.InterruptionOptions(rawValue: optValue)
                    if opts.contains(.shouldResume) && self._state == .paused {
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
                }
                DispatchQueue.main.async { [weak self] in
                    self?.onInterruption?("ended")
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
        guard onAmplitude != nil || onSpectrum != nil else { return }
        _tapInstalled      = true
        _lastAmplitudeTime = 0
        _lastSpectrumTime  = 0

        // Build Hann window once (lazily).
        if _hannWindow[0] == 0 && _hannWindow[511] == 0 {
            vDSP_hann_windowD(&_hannWindow, 1024, Int32(vDSP_HANN_NORM))
        }
        // Create FFT setup once (lazily).
        if _fftSetup == nil {
            _fftSetup = vDSP_DFT_zop_CreateSetupD(nil, 1024, vDSP_DFT_FORWARD)
        }

        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self else { return }

            let now = Date.timeIntervalSinceReferenceDate
            guard let channelData = buffer.floatChannelData else { return }
            let frameCount   = Int(buffer.frameLength)
            let channelCount = Int(buffer.format.channelCount)
            guard frameCount > 0 else { return }

            // ── Amplitude (~20 Hz) ────────────────────────────────────────────
            if let onAmplitude = self.onAmplitude,
               now - self._lastAmplitudeTime >= 0.05 {
                self._lastAmplitudeTime = now
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
                DispatchQueue.main.async { onAmplitude(min(rms, 1.0), min(peak, 1.0)) }
            }

            // ── Spectrum FFT (~10 Hz) ─────────────────────────────────────────
            let sampleRate = buffer.format.sampleRate
            if let onSpectrum = self.onSpectrum,
               let setup = self._fftSetup,
               now - self._lastSpectrumTime >= 0.1 {
                self._lastSpectrumTime = now

                // Mix to mono (double) and apply Hann window.
                let nSamples = min(frameCount, 1024)
                for i in 0..<nSamples {
                    var s: Double = 0
                    for ch in 0..<channelCount { s += Double(channelData[ch][i]) }
                    self._fftWindowedReal[i] = s / Double(channelCount) * self._hannWindow[i]
                    self._fftWindowedImag[i] = 0
                }
                // Zero-pad if needed.
                if nSamples < 1024 {
                    for i in nSamples..<1024 { self._fftWindowedReal[i] = 0; self._fftWindowedImag[i] = 0 }
                }

                // In-place complex DFT.
                var outReal = [Double](repeating: 0, count: 1024)
                var outImag = [Double](repeating: 0, count: 1024)
                self._fftWindowedReal.withUnsafeBufferPointer { rPtr in
                    self._fftWindowedImag.withUnsafeBufferPointer { iPtr in
                        outReal.withUnsafeMutableBufferPointer { orPtr in
                            outImag.withUnsafeMutableBufferPointer { oiPtr in
                                vDSP_DFT_ExecuteD(setup,
                                    rPtr.baseAddress!, iPtr.baseAddress!,
                                    orPtr.baseAddress!, oiPtr.baseAddress!)
                            }
                        }
                    }
                }

                // Compute magnitude of first 512 bins, then average into 256 output bins.
                for k in 0..<512 {
                    self._fftMagnitudes[k] = (outReal[k]*outReal[k] + outImag[k]*outImag[k]).squareRoot() / 512.0
                }

                let spectrum: [Float] = (0..<256).map { i in
                    Float(min((self._fftMagnitudes[i*2] + self._fftMagnitudes[i*2+1]) * 0.5, 1.0))
                }
                DispatchQueue.main.async { onSpectrum(spectrum, sampleRate) }
            }
        }
        logger.debug("Amplitude/spectrum tap installed")
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
#endif // os(iOS)
