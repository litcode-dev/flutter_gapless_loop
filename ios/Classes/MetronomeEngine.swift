#if os(iOS)
import AVFoundation
import os.log

/// Generates a single-bar PCM buffer (accent + N-1 clicks + silence) and loops
/// it indefinitely via `AVAudioPlayerNode.scheduleBuffer(.loops)`.
///
/// Beat-tick events (UI hint, ±5 ms jitter) are fired via `DispatchSourceTimer`.
///
/// All public methods must be called from the main thread (or `audioQueue`-safe callers).
@available(iOS 14.0, *)
final class MetronomeEngine {

    // MARK: - Callbacks (called on main thread)

    /// Beat index: 0 = downbeat, 1…N-1 = regular beat.
    var onBeatTick: ((Int) -> Void)?
    /// Recoverable error message.
    var onError: ((String) -> Void)?

    // MARK: - Private state

    private var audioEngine  = AVAudioEngine()
    private var playerNode   = AVAudioPlayerNode()
    private let logger       = Logger(subsystem: "com.fluttergaplessloop", category: "Metronome")

    private var clickBuffer:  AVAudioPCMBuffer?
    private var accentBuffer: AVAudioPCMBuffer?
    private var barBuffer:    AVAudioPCMBuffer?

    private var currentBpm:         Double = 120
    private var currentBeatsPerBar: Int    = 4
    private var isRunning = false

    private var beatTimer: DispatchSourceTimer?
    private var beatIndex = 0

    // MARK: - Public API

    /// Decodes click/accent bytes from temp files, builds the bar buffer, and starts looping.
    func start(bpm: Double,
               beatsPerBar: Int,
               clickData: Data,
               accentData: Data,
               fileExtension: String) {
        do {
            clickBuffer  = try loadBuffer(from: clickData,  ext: fileExtension)
            accentBuffer = try loadBuffer(from: accentData, ext: fileExtension)
        } catch {
            onError?(error.localizedDescription)
            return
        }

        currentBpm         = bpm
        currentBeatsPerBar = beatsPerBar

        guard let bar = buildBarBuffer(bpm: bpm, beatsPerBar: beatsPerBar) else {
            onError?("MetronomeEngine: failed to build bar buffer")
            return
        }
        barBuffer = bar

        setupAndPlay(format: bar.format)
        startBeatTimer(bpm: bpm, beatsPerBar: beatsPerBar)
        isRunning = true
        logger.info("MetronomeEngine started: \(bpm) BPM \(beatsPerBar)/4")
    }

    /// Stops playback immediately.
    func stop() {
        stopBeatTimer()
        playerNode.stop()
        isRunning = false
    }

    /// Rebuilds the bar buffer at the new tempo and restarts. No-op if not started.
    func setBpm(_ bpm: Double) {
        guard isRunning else { return }
        currentBpm = bpm
        rebuildAndRestart()
    }

    /// Rebuilds the bar buffer with the new time signature and restarts. No-op if not started.
    func setBeatsPerBar(_ beatsPerBar: Int) {
        guard isRunning else { return }
        currentBeatsPerBar = beatsPerBar
        rebuildAndRestart()
    }

    /// Releases all native resources.
    func dispose() {
        stop()
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.detach(playerNode)
    }

    // MARK: - Private: audio graph

    private func setupAndPlay(format: AVAudioFormat) {
        // Tear down old graph before rebuilding.
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine = AVAudioEngine()
        playerNode  = AVAudioPlayerNode()

        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)

        do {
            try audioEngine.start()
        } catch {
            onError?("AVAudioEngine.start() failed: \(error.localizedDescription)")
            return
        }

        guard let bar = barBuffer else { return }
        playerNode.scheduleBuffer(bar, at: nil, options: .loops, completionHandler: nil)
        playerNode.play()
    }

    private func rebuildAndRestart() {
        guard let bar = buildBarBuffer(bpm: currentBpm, beatsPerBar: currentBeatsPerBar) else {
            onError?("MetronomeEngine: failed to rebuild bar buffer")
            return
        }
        barBuffer = bar
        stopBeatTimer()
        setupAndPlay(format: bar.format)
        beatIndex = 0
        startBeatTimer(bpm: currentBpm, beatsPerBar: currentBeatsPerBar)
    }

    // MARK: - Private: bar buffer generation

    /// Builds a bar buffer: accent at frame 0, click at beat positions 1…N-1, silence elsewhere.
    private func buildBarBuffer(bpm: Double, beatsPerBar: Int) -> AVAudioPCMBuffer? {
        guard let click = clickBuffer, let accent = accentBuffer else { return nil }

        let format      = click.format
        let sampleRate  = format.sampleRate
        let beatFrames  = AVAudioFrameCount(sampleRate * 60.0 / bpm)
        let barFrames   = beatFrames * AVAudioFrameCount(beatsPerBar)

        guard let bar = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: barFrames) else {
            return nil
        }
        bar.frameLength = barFrames
        // AVAudioPCMBuffer data is zero-initialised by the framework.

        mixInto(bar, source: accent, atFrame: 0)
        for beat in 1..<beatsPerBar {
            mixInto(bar,
                    source: click,
                    atFrame: AVAudioFramePosition(beat) * AVAudioFramePosition(beatFrames))
        }

        applyMicroFade(bar)
        return bar
    }

    /// Adds [source] samples into [dest] starting at [offsetFrame].
    private func mixInto(_ dest: AVAudioPCMBuffer,
                         source: AVAudioPCMBuffer,
                         atFrame offsetFrame: AVAudioFramePosition) {
        guard let srcCh = source.floatChannelData,
              let dstCh = dest.floatChannelData else { return }

        let channelCount  = Int(dest.format.channelCount)
        let destRemaining = Int(dest.frameLength) - Int(offsetFrame)
        guard destRemaining > 0 else { return }
        let framesToCopy  = Int(min(source.frameLength, AVAudioFrameCount(destRemaining)))

        for ch in 0..<channelCount {
            let src = srcCh[ch]
            let dst = dstCh[ch]
            for i in 0..<framesToCopy {
                dst[Int(offsetFrame) + i] += src[i]
            }
        }

        // Clamp to [-1, 1] to prevent digital distortion after mixing.
        for ch in 0..<channelCount {
            let dst = dstCh[ch]
            for i in 0..<Int(dest.frameLength) {
                dst[i] = max(-1.0, min(1.0, dst[i]))
            }
        }
    }

    /// Applies a 5 ms linear fade-in at frame 0 and fade-out at the last frame.
    private func applyMicroFade(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let sampleRate  = buffer.format.sampleRate
        let fadeFrames  = max(1, Int(sampleRate * 0.005))
        let totalFrames = Int(buffer.frameLength)
        let nCh         = Int(buffer.format.channelCount)

        for i in 0..<fadeFrames {
            let gain = Float(i) / Float(fadeFrames)
            for ch in 0..<nCh {
                channels[ch][i] *= gain
                let endIdx = totalFrames - 1 - i
                if endIdx > i { channels[ch][endIdx] *= gain }
            }
        }
    }

    // MARK: - Private: byte loading

    /// Writes [data] to a temp file, reads it with AVAudioFile, returns a PCM buffer.
    private func loadBuffer(from data: Data, ext: String) throws -> AVAudioPCMBuffer {
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "metronome_\(UInt64(Date().timeIntervalSince1970 * 1000)).\(ext)"
            )
        try data.write(to: tmpURL)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let file = try AVAudioFile(forReading: tmpURL)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw NSError(
                domain: "MetronomeEngine",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to allocate AVAudioPCMBuffer"]
            )
        }
        try file.read(into: buffer)
        return buffer
    }

    // MARK: - Private: beat timer

    private func startBeatTimer(bpm: Double, beatsPerBar: Int) {
        beatIndex = 0
        let beatNs = UInt64(60_000_000_000.0 / bpm)

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now(),
            repeating: .nanoseconds(Int(beatNs)),
            leeway: .milliseconds(5)
        )
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.onBeatTick?(self.beatIndex)
            self.beatIndex = (self.beatIndex + 1) % beatsPerBar
        }
        timer.resume()
        beatTimer = timer
    }

    private func stopBeatTimer() {
        beatTimer?.cancel()
        beatTimer = nil
        beatIndex = 0
    }
}
#endif
