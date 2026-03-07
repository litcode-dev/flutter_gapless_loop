package com.fluttergaplessloop

import android.content.Context
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.PlaybackParams
import android.os.Build
import android.os.Process
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.concurrent.Semaphore
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

/*
 * ARCHITECTURE NOTE — Why AudioTrack MODE_STREAM over Oboe or setLoopPoints()
 *
 * Three options were evaluated:
 *
 * Option A — AudioTrack.setLoopPoints() (MODE_STATIC):
 *   Rejected: 2 MB static buffer limit disqualifies large audio files. Known OEM
 *   inconsistencies on Huawei/Samsung make it unreliable for production.
 *
 * Option B — Oboe (C++ via JNI, CMakeLists.txt):
 *   Rejected: Oboe's primary advantage is ultra-low latency for the INPUT path
 *   (real-time instruments, monitoring). For pure PLAYBACK the latency is equivalent
 *   to AudioTrack, and the added NDK build complexity makes the plugin harder to
 *   integrate in host apps. No benefit for this playback-only use case.
 *
 * Option C — AudioTrack WRITE_FLOAT MODE_STREAM (CHOSEN):
 *   A dedicated write thread with THREAD_PRIORITY_URGENT_AUDIO feeds the AudioTrack
 *   a continuous stream of PCM. The write thread wraps the read pointer at the loop
 *   boundary atomically — the hardware renderer sees an uninterrupted byte stream,
 *   producing zero gap. This is the direct Android analog of iOS AVAudioEngine's
 *   scheduleBuffer(.loops).
 *
 * Threading:
 *   Main thread         ← Flutter method channel calls, EventSink dispatch
 *   IO coroutine        ← MediaExtractor + MediaCodec file decode
 *   writeThread         ← AudioTrack.write(WRITE_BLOCKING), wrap-around logic
 *   engineScope(Main)   ← state change callbacks dispatched to Dart
 */

/**
 * Equal-power pan formula.
 *
 * Maps [pan] ∈ [−1, 1] to (leftGain, rightGain) using:
 *   angle = (pan + 1) × π/4
 *   leftGain  = cos(angle)
 *   rightGain = sin(angle)
 *
 * At centre (pan=0):  angle=π/4 → both gains ≈ 0.707 (−3 dB each).
 * At full left (−1):  angle=0   → leftGain=1, rightGain=0.
 * At full right (+1): angle=π/2 → leftGain=0, rightGain=1.
 */
internal fun panToGains(pan: Float): Pair<Float, Float> {
    val angle = (pan + 1f) * (Math.PI.toFloat() / 4f)
    return Pair(kotlin.math.cos(angle), kotlin.math.sin(angle))
}

/**
 * Core audio engine for sample-accurate gapless looping on Android.
 *
 * ## Playback Modes (auto-selected based on configuration)
 * - **Mode A** (default): full file, no crossfade — write thread wraps at `totalFrames`
 * - **Mode B**: loop region set, no crossfade — write thread wraps at `loopEndFrame`
 * - **Mode C**: full file + crossfade enabled — crossfade block inserted at wrap point
 * - **Mode D**: loop region + crossfade enabled
 *
 * Mode is determined by whether `loopRegion` covers the full file and whether
 * `crossfadeDuration > 0`. The write thread re-evaluates on every wrap.
 *
 * ## Usage
 * ```kotlin
 * val engine = LoopAudioEngine(context)
 * engine.onStateChange = { state -> ... }
 * coroutineScope.launch { engine.loadFile("/sdcard/loop.mp3") }
 * engine.play()
 * ```
 */
class LoopAudioEngine(private val context: Context) {

    companion object {
        private const val TAG = "LoopAudioEngine"

        /**
         * AudioTrack buffer size multiplier.
         * 4× minimum provides headroom for the write thread without excessive latency.
         */
        private const val BUFFER_MULTIPLIER = 4
    }

    // ─── Public callbacks ─────────────────────────────────────────────────────

    /** Invoked on every [EngineState] transition. Always called on the main thread. */
    var onStateChange: ((EngineState) -> Unit)? = null

    /** Invoked when a non-fatal or fatal error occurs. Always called on the main thread. */
    var onError: ((LoopEngineError) -> Unit)? = null

    /**
     * Invoked when an audio route change requires a pause.
     * The string matches iOS: "headphonesUnplugged".
     */
    var onRouteChange: ((String) -> Unit)? = null

    /** Invoked when BPM detection completes after a load. Always called on the main thread. */
    var onBpmDetected: ((BpmDetectionResult) -> Unit)? = null

    /**
     * Invoked with (rms, peak) amplitude in [0, 1] approximately 20 times per second
     * while the engine is playing. Always called on the main thread.
     */
    var onAmplitude: ((Float, Float) -> Unit)? = null

    // ─── Public read-only state ───────────────────────────────────────────────

    private var _state: EngineState = EngineState.Idle

    /** Current engine state. */
    val state: EngineState get() = _state

    /** Total duration of the loaded file in seconds. */
    var duration: Double = 0.0
        private set

    /**
     * Current playback position in seconds.
     *
     * Read from [currentFrameAtomic] which is updated by the write thread.
     * Thread-safe: no blocking.
     */
    val currentTime: Double
        get() {
            val frames = currentFrameAtomic.get()
            return if (sampleRate > 0) frames.toDouble() / sampleRate.toDouble() else 0.0
        }

    /** Coroutine job for background BPM detection. Cancelled on each new load and dispose(). */
    @Volatile
    private var bpmJob: Job? = null

    // ─── Private: decoded audio ───────────────────────────────────────────────

    private var pcmBuffer: FloatArray? = null
    private var sampleRate: Int = 44100
    private var channelCount: Int = 2
    private var totalFrames: Int = 0

    // ─── Private: loop region ─────────────────────────────────────────────────

    /**
     * Loop region stored as an atomic pair to prevent the write thread from observing
     * a partially updated state (e.g. start updated but end not yet).
     */
    private data class LoopRegion(val start: Int, val end: Int)
    private val loopRegionRef = AtomicReference(LoopRegion(0, 0))

    private val loopStartFrame: Int get() = loopRegionRef.get().start
    private val loopEndFrame:   Int get() = loopRegionRef.get().end

    // ─── Private: crossfade ───────────────────────────────────────────────────

    private var crossfadeEngine: CrossfadeEngine? = null
    private var crossfadeDuration: Double = 0.0

    /**
     * Pre-computed crossfade block written at the loop boundary.
     * Updated atomically so the write thread always reads a complete block.
     */
    private val crossfadeBlockRef = AtomicReference<FloatArray?>(null)

    // ─── Private: write thread ────────────────────────────────────────────────

    /** Signals the write thread to exit its loop. */
    @Volatile private var stopRequested = false

    /** Signals the write thread to suspend on [pauseSemaphore]. */
    @Volatile private var pauseRequested = false

    /**
     * Suspends the write thread during pause without busy-waiting.
     * Starts at 0 (blocked). [resume] releases to unblock.
     */
    private val pauseSemaphore = Semaphore(0)

    /** Monotonically tracked playback frame position, updated by the write thread. */
    private val currentFrameAtomic = AtomicLong(0L)

    /** Last time (ms) an amplitude event was dispatched. Throttles to ~20 Hz. */
    @Volatile private var lastAmplitudeTimeMs: Long = 0

    private var writeThread: Thread? = null
    private var audioTrack: AudioTrack? = null

    // ─── Private: session / coroutines ───────────────────────────────────────

    private val sessionManager = AudioSessionManager(context)

    /**
     * Coroutine scope for state change callbacks on the main thread.
     * [SupervisorJob] ensures one failed callback does not cancel other callbacks.
     */
    private val engineScope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    // ─── Initialization ───────────────────────────────────────────────────────

    init {
        wireSessionCallbacks()
        sessionManager.initialize()
    }

    // ─── Public API ──────────────────────────────────────────────────────────

    /**
     * Decodes the audio file at [path] and transitions to [EngineState.Ready].
     *
     * Suspends on [Dispatchers.IO] during MediaCodec decode. Call from a coroutine.
     *
     * @throws LoopAudioException on any IO or decode failure.
     */
    suspend fun loadFile(path: String) {
        bpmJob?.cancel()
        setState(EngineState.Loading)
        try {
            val decoded = AudioFileLoader.decode(path)
            AudioFileLoader.applyMicroFade(decoded.pcm, decoded.sampleRate, decoded.channelCount)
            commitDecodedAudio(decoded)
            setState(EngineState.Ready)
            launchBpmDetection()
        } catch (e: LoopAudioException) {
            setState(EngineState.Error(e.error))
            onError?.invoke(e.error)
            throw e
        } catch (e: Exception) {
            val err = LoopEngineError.DecodeFailed(e.message ?: "Unknown error")
            setState(EngineState.Error(err))
            onError?.invoke(err)
            throw LoopAudioException(err)
        }
    }

    /**
     * Decodes a Flutter asset identified by [assetKey] using [assetFd].
     *
     * @param assetKey Human-readable asset key (for logging).
     * @param assetFd  [android.content.res.AssetFileDescriptor] from Flutter asset registry.
     * @throws LoopAudioException on decode failure.
     */
    suspend fun loadAsset(assetKey: String, assetFd: android.content.res.AssetFileDescriptor) {
        bpmJob?.cancel()
        setState(EngineState.Loading)
        try {
            val decoded = AudioFileLoader.decodeAsset(assetFd)
            AudioFileLoader.applyMicroFade(decoded.pcm, decoded.sampleRate, decoded.channelCount)
            commitDecodedAudio(decoded)
            setState(EngineState.Ready)
            launchBpmDetection()
            Log.i(TAG, "loadAsset complete: $assetKey")
        } catch (e: LoopAudioException) {
            setState(EngineState.Error(e.error))
            onError?.invoke(e.error)
            throw e
        } catch (e: Exception) {
            val err = LoopEngineError.DecodeFailed(e.message ?: "Unknown error")
            setState(EngineState.Error(err))
            onError?.invoke(err)
            throw LoopAudioException(err)
        }
    }

    /**
     * Starts playback from [loopStartFrame].
     *
     * Requests audio focus before starting. Fires [onError] and returns if focus denied.
     */
    fun play() {
        if (_state != EngineState.Ready && _state != EngineState.Stopped) {
            Log.w(TAG, "play() ignored: state=$_state")
            return
        }
        if (!sessionManager.requestAudioFocus()) {
            onError?.invoke(
                LoopEngineError.AudioFocusDenied("AudioManager denied AUDIOFOCUS_GAIN")
            )
            return
        }
        currentFrameAtomic.set(loopStartFrame.toLong())
        audioTrack?.play()
        applyPlaybackRate()
        startWriteThread()
        setState(EngineState.Playing)
    }

    /**
     * Pauses playback, keeping the [AudioTrack] warm so [resume] has no latency spike.
     *
     * Sets [pauseRequested]; the write thread suspends on [pauseSemaphore] on its next
     * iteration. [AudioTrack.pause] stops the hardware renderer immediately.
     */
    fun pause() {
        if (_state != EngineState.Playing) {
            Log.w(TAG, "pause() ignored: state=$_state")
            return
        }
        pauseRequested = true
        audioTrack?.pause()
        sessionManager.abandonAudioFocus()
        setState(EngineState.Paused)
    }

    /**
     * Resumes a paused engine.
     *
     * Releases [pauseSemaphore] to unblock the write thread, then calls [AudioTrack.play].
     */
    fun resume() {
        if (_state != EngineState.Paused) {
            Log.w(TAG, "resume() ignored: state=$_state")
            return
        }
        if (!sessionManager.requestAudioFocus()) {
            onError?.invoke(
                LoopEngineError.AudioFocusDenied("AudioManager denied AUDIOFOCUS_GAIN on resume")
            )
            return
        }
        pauseRequested = false
        pauseSemaphore.release()
        audioTrack?.play()
        setState(EngineState.Playing)
    }

    /**
     * Stops playback and resets the play cursor to [loopStartFrame].
     *
     * Joins the write thread before returning so [AudioTrack] is safe to manipulate.
     */
    fun stop() {
        stopWriteThread()
        audioTrack?.flush()
        currentFrameAtomic.set(loopStartFrame.toLong())
        sessionManager.abandonAudioFocus()
        setState(EngineState.Stopped)
    }

    /**
     * Sets a custom loop region in seconds.
     *
     * Zero-crossing alignment is applied to both boundaries. The write thread picks up
     * the new [loopRegionRef] on its next wrap. Crossfade block is recomputed if active.
     */
    fun setLoopRegion(start: Double, end: Double) {
        val buf = pcmBuffer ?: return
        if (start >= end || start < 0.0 || end > duration) {
            onError?.invoke(LoopEngineError.InvalidLoopRegion(start, end))
            return
        }
        val startFrame   = (start * sampleRate).toInt().coerceIn(0, totalFrames - 1)
        val endFrame     = (end   * sampleRate).toInt().coerceIn(startFrame + 1, totalFrames)
        val windowFrames = (sampleRate * 0.01).toInt() // 10 ms search window

        val alignedStart = findNearestZeroCrossing(buf, startFrame, channelCount, windowFrames, true)
        val alignedEnd   = findNearestZeroCrossing(buf, endFrame,   channelCount, windowFrames, false)

        loopRegionRef.set(LoopRegion(alignedStart, alignedEnd))

        if (crossfadeDuration > 0.0) {
            recomputeCrossfadeBlock(buf)
        }
        Log.i(TAG, "setLoopRegion: $alignedStart–$alignedEnd frames ($start–${end}s)")
    }

    /**
     * Sets or clears the crossfade duration.
     *
     * - duration == 0: clears crossfade (Mode A or B)
     * - duration > 0: pre-computes crossfade block (Mode C or D)
     *
     * Must not exceed 50% of the current loop region duration.
     */
    fun setCrossfadeDuration(seconds: Double) {
        val buf = pcmBuffer ?: return
        val loopDuration = (loopEndFrame - loopStartFrame).toDouble() / sampleRate
        val maxCrossfade = loopDuration * 0.5

        if (seconds > maxCrossfade) {
            onError?.invoke(LoopEngineError.CrossfadeTooLong(seconds, maxCrossfade))
            return
        }

        crossfadeDuration = seconds
        if (seconds > 0.0) {
            val eng = CrossfadeEngine(sampleRate, channelCount)
            eng.configure(seconds)
            crossfadeEngine = eng
            recomputeCrossfadeBlock(buf)
            Log.i(TAG, "setCrossfadeDuration: ${seconds}s (${eng.fadeFrames} frames)")
        } else {
            crossfadeEngine = null
            crossfadeBlockRef.set(null)
            Log.i(TAG, "setCrossfadeDuration: cleared")
        }
    }

    /**
     * Sets playback volume in the range [0.0, 1.0].
     * Delegates to [AudioTrack.setVolume] (software gain multiplier).
     */
    fun setVolume(volume: Float) {
        audioTrack?.setVolume(volume.coerceIn(0f, 1f))
    }

    /** Backing field for [setPan]. Written from main thread; read by [applyPan]. */
    @Volatile private var panValue: Float = 0f

    /**
     * Sets the stereo pan position. [pan] is in [−1.0, 1.0].
     * Called on the main thread. [AudioTrack.setStereoVolume] is thread-safe.
     */
    fun setPan(pan: Float) {
        panValue = pan.coerceIn(-1f, 1f)
        applyPan()
    }

    private fun applyPan() {
        val (leftGain, rightGain) = panToGains(panValue)
        audioTrack?.setStereoVolume(leftGain, rightGain)
    }

    /** Backing field for [setPlaybackRate]. Written from main thread; read by [applyPlaybackRate]. */
    @Volatile private var playbackRate: Float = 1f

    /**
     * Sets the playback rate (speed) while preserving pitch.
     * [rate] is a multiplier: 1.0 = normal, 2.0 = double speed, 0.5 = half speed.
     * Uses [AudioTrack.setPlaybackParams] on API 23+. No-op on older devices.
     * Called on the main thread. Thread-safe via @Volatile.
     */
    fun setPlaybackRate(rate: Float) {
        playbackRate = rate.coerceIn(0.25f, 4.0f)
        applyPlaybackRate()
    }

    private fun applyPlaybackRate() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            audioTrack?.playbackParams = PlaybackParams().setSpeed(playbackRate)
        }
    }

    /**
     * Seeks to [seconds] in the file.
     *
     * Updates [currentFrameAtomic] atomically. The write thread reads this at the
     * start of each chunk fill, so the seek takes effect at the next chunk.
     */
    fun seek(seconds: Double) {
        if (seconds < 0.0 || seconds > duration) {
            onError?.invoke(LoopEngineError.SeekOutOfBounds(seconds, duration))
            return
        }
        val targetFrame = (seconds * sampleRate).toLong()
            .coerceIn(loopStartFrame.toLong(), loopEndFrame.toLong())
        currentFrameAtomic.set(targetFrame)
        Log.i(TAG, "seek: ${seconds}s → frame $targetFrame")
    }

    /**
     * Releases all resources. After this call the engine must not be reused.
     */
    fun dispose() {
        stopWriteThread()
        sessionManager.dispose()
        audioTrack?.release()
        audioTrack = null
        bpmJob?.cancel()
        bpmJob = null
        pcmBuffer = null
        crossfadeBlockRef.set(null)
        crossfadeEngine = null
        engineScope.cancel()
        _state = EngineState.Idle
        Log.i(TAG, "Disposed")
    }

    // ─── Private: audio setup ─────────────────────────────────────────────────

    /**
     * Stores decoded audio and builds a new [AudioTrack].
     * Called inside [loadFile] and [loadAsset] after successful decode.
     */
    private fun commitDecodedAudio(decoded: AudioFileLoader.DecodedAudio) {
        stopWriteThread()

        pcmBuffer    = decoded.pcm
        sampleRate   = decoded.sampleRate
        channelCount = decoded.channelCount
        totalFrames  = decoded.totalFrames
        duration     = decoded.totalFrames.toDouble() / decoded.sampleRate

        loopRegionRef.set(LoopRegion(0, totalFrames))
        currentFrameAtomic.set(0L)

        crossfadeBlockRef.set(null)
        crossfadeEngine    = null
        crossfadeDuration  = 0.0

        buildAudioTrack()
    }

    /**
     * Builds an [AudioTrack] configured for the current [sampleRate] and [channelCount].
     *
     * Uses [AudioFormat.ENCODING_PCM_FLOAT] for direct float output (API 21+).
     * Buffer size is 4× the system minimum to prevent underruns on slower devices.
     */
    private fun buildAudioTrack() {
        audioTrack?.release()

        val minBuf = AudioTrack.getMinBufferSize(
            sampleRate,
            if (channelCount == 1) AudioFormat.CHANNEL_OUT_MONO else AudioFormat.CHANNEL_OUT_STEREO,
            AudioFormat.ENCODING_PCM_FLOAT
        )
        val bufBytes = maxOf(minBuf * BUFFER_MULTIPLIER, 4096 * channelCount * 4)

        audioTrack = AudioTrack.Builder()
            .setAudioAttributes(sessionManager.audioAttributes)
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
                    .setSampleRate(sampleRate)
                    .setChannelMask(
                        if (channelCount == 1) AudioFormat.CHANNEL_OUT_MONO
                        else AudioFormat.CHANNEL_OUT_STEREO
                    )
                    .build()
            )
            .setBufferSizeInBytes(bufBytes)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()

        Log.i(TAG, "AudioTrack built: ${sampleRate}Hz ${channelCount}ch buf=${bufBytes}B")
        applyPan() // Restore pan setting after AudioTrack recreation
        applyPlaybackRate() // Restore playback rate after AudioTrack recreation
    }

    // ─── Private: write thread ────────────────────────────────────────────────

    /**
     * Starts the audio write thread.
     *
     * The write thread:
     * 1. Sets priority to [Process.THREAD_PRIORITY_URGENT_AUDIO].
     * 2. Allocates a write buffer ONCE before the loop.
     * 3. Fills the buffer from [pcmBuffer], wrapping at [loopEndFrame].
     * 4. Inserts the pre-computed crossfade block at the wrap point if active.
     * 5. Writes to [AudioTrack] using [AudioTrack.WRITE_BLOCKING].
     * 6. Suspends on [pauseSemaphore] when [pauseRequested] is true.
     * 7. Exits when [stopRequested] is true.
     */
    private fun startWriteThread() {
        stopRequested      = false
        pauseRequested     = false
        lastAmplitudeTimeMs = 0

        writeThread = Thread {
            Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)

            val track = audioTrack ?: run {
                Log.e(TAG, "Write thread: null AudioTrack")
                return@Thread
            }
            val buffer = pcmBuffer ?: run {
                Log.e(TAG, "Write thread: null pcmBuffer")
                return@Thread
            }

            val chunkFrames  = track.bufferSizeInFrames / 2
            val chunkSamples = chunkFrames * channelCount

            // Allocated ONCE before the write loop — no allocation inside the loop
            val writeBuffer = FloatArray(chunkSamples)

            Log.d(TAG, "Write thread started: chunkFrames=$chunkFrames")

            try {
                while (!stopRequested) {

                    // ── Pause: suspend without busy-waiting ───────────────────
                    if (pauseRequested) {
                        try {
                            pauseSemaphore.acquire()
                        } catch (e: InterruptedException) {
                            break
                        }
                        if (stopRequested) break
                        continue
                    }

                    val region       = loopRegionRef.get()
                    val regionStart  = region.start
                    val regionEnd    = region.end
                    var currentFrame = currentFrameAtomic.get().toInt()

                    // ── Fill writeBuffer with loop-wrapped PCM ─────────────────
                    var writeIdx = 0
                    while (writeIdx < chunkSamples && !stopRequested && !pauseRequested) {
                        if (currentFrame >= regionEnd) {
                            // Loop boundary — insert crossfade block if configured
                            val cfBlock = crossfadeBlockRef.get()
                            if (cfBlock != null && writeIdx + cfBlock.size <= chunkSamples) {
                                cfBlock.copyInto(writeBuffer, writeIdx)
                                writeIdx += cfBlock.size
                            }
                            // Wrap back to loop start (Mode A/C: start=0, Mode B/D: custom)
                            currentFrame = regionStart
                        }

                        // Copy as many samples as possible before hitting regionEnd
                        val framesUntilEnd  = regionEnd - currentFrame
                        val samplesUntilEnd = framesUntilEnd * channelCount
                        val samplesNeeded   = chunkSamples - writeIdx
                        val samplesToCopy   = minOf(samplesNeeded, samplesUntilEnd)

                        val srcOffset = currentFrame * channelCount
                        buffer.copyInto(writeBuffer, writeIdx, srcOffset, srcOffset + samplesToCopy)
                        writeIdx     += samplesToCopy
                        currentFrame += samplesToCopy / channelCount
                    }

                    currentFrameAtomic.set(currentFrame.toLong())

                    // ── Write to AudioTrack ────────────────────────────────────
                    // WRITE_BLOCKING: blocks until AudioTrack consumes all data.
                    // Never use WRITE_NON_BLOCKING — partial writes break the loop.
                    if (writeIdx > 0) {
                        val written = track.write(writeBuffer, 0, writeIdx, AudioTrack.WRITE_BLOCKING)
                        if (written < 0) {
                            val err = LoopEngineError.AudioTrackError(written)
                            Log.e(TAG, "AudioTrack.write error: $written")
                            engineScope.launch {
                                setState(EngineState.Error(err))
                                onError?.invoke(err)
                            }
                            break
                        }

                        // ── Amplitude measurement (~20 Hz) ─────────────────────
                        val amplitudeCallback = onAmplitude
                        if (amplitudeCallback != null) {
                            val nowMs = System.currentTimeMillis()
                            if (nowMs - lastAmplitudeTimeMs >= 50) {
                                lastAmplitudeTimeMs = nowMs
                                var sumSq = 0f
                                var peak  = 0f
                                for (i in 0 until writeIdx) {
                                    val s = writeBuffer[i]
                                    sumSq += s * s
                                    val abs = if (s < 0f) -s else s
                                    if (abs > peak) peak = abs
                                }
                                val rms = kotlin.math.sqrt(sumSq / writeIdx)
                                val rmsC  = rms.coerceIn(0f, 1f)
                                val peakC = peak.coerceIn(0f, 1f)
                                engineScope.launch {
                                    amplitudeCallback(rmsC, peakC)
                                }
                            }
                        }
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Write thread exception: ${e.message}", e)
                val err = LoopEngineError.DecodeFailed("Write thread: ${e.message}")
                engineScope.launch {
                    setState(EngineState.Error(err))
                    onError?.invoke(err)
                }
            }

            Log.d(TAG, "Write thread exited")
        }

        writeThread?.isDaemon = true
        writeThread?.start()
    }

    /**
     * Signals the write thread to stop and waits up to 2 s for it to exit.
     *
     * If the thread is blocked on [pauseSemaphore], releasing it lets it see
     * [stopRequested] and exit cleanly.
     */
    private fun stopWriteThread() {
        stopRequested = true
        if (pauseRequested) {
            pauseRequested = false
            pauseSemaphore.release()
        }
        writeThread?.let { thread ->
            thread.interrupt()
            thread.join(2_000L)
            if (thread.isAlive) Log.w(TAG, "Write thread did not exit within 2 s")
        }
        writeThread = null
        audioTrack?.pause()
    }

    // ─── Private: zero-crossing detection ────────────────────────────────────

    /**
     * Scans a window of [searchWindowFrames] from [boundary] for the nearest zero-crossing.
     *
     * A zero-crossing is where consecutive frames change sign in the first channel.
     * Returns [boundary] unchanged if no crossing is found within the window.
     *
     * @param buffer             The PCM FloatArray.
     * @param boundary           Initial boundary frame index.
     * @param channelCount       Number of interleaved channels.
     * @param searchWindowFrames Maximum frames to search.
     * @param searchForward      true = search forward; false = search backward.
     */
    private fun findNearestZeroCrossing(
        buffer: FloatArray,
        boundary: Int,
        channelCount: Int,
        searchWindowFrames: Int,
        searchForward: Boolean
    ): Int {
        val bufferFrames = buffer.size / channelCount
        if (searchForward) {
            val limit = minOf(boundary + searchWindowFrames, bufferFrames - 1)
            for (frame in boundary until limit) {
                val cur  = buffer[frame * channelCount]
                val next = buffer[(frame + 1) * channelCount]
                if (cur * next <= 0f) return frame
            }
        } else {
            val limit = maxOf(boundary - searchWindowFrames, 1)
            for (frame in boundary downTo limit) {
                val prev = buffer[(frame - 1) * channelCount]
                val cur  = buffer[frame * channelCount]
                if (prev * cur <= 0f) return frame
            }
        }
        return boundary
    }

    // ─── Private: crossfade recompute ─────────────────────────────────────────

    /**
     * Recomputes and atomically replaces the crossfade block.
     *
     * The block is a pre-blended [FloatArray] the write thread inserts at the boundary.
     * Computed here (outside the write thread) so the write thread never allocates.
     */
    private fun recomputeCrossfadeBlock(buffer: FloatArray) {
        val engine     = crossfadeEngine ?: return
        val fadeFrames = engine.fadeFrames
        if (fadeFrames <= 0) return

        val fadeSamples = fadeFrames * channelCount
        val startSample = loopStartFrame * channelCount
        val endSample   = loopEndFrame   * channelCount

        if (startSample + fadeSamples > buffer.size || endSample - fadeSamples < 0) {
            Log.w(TAG, "Crossfade block exceeds buffer bounds — skipping")
            return
        }

        val head  = buffer.copyOfRange(startSample, startSample + fadeSamples)
        val tail  = buffer.copyOfRange(endSample - fadeSamples, endSample)
        val block = engine.computeCrossfadeBlock(tail, head)
        crossfadeBlockRef.set(block)
        Log.d(TAG, "Crossfade block recomputed: ${block.size} samples")
    }

    // ─── Private: BPM detection ───────────────────────────────────────────────

    /**
     * Launches BPM detection on [Dispatchers.IO].
     * Captures the current [pcmBuffer], [sampleRate], and [channelCount] by value
     * so the write thread cannot cause a data race.
     * On completion, invokes [onBpmDetected] on the main thread.
     */
    private fun launchBpmDetection() {
        val pcm = pcmBuffer ?: return
        val sr  = sampleRate
        val ch  = channelCount
        Log.i(TAG, "BPM detection started: ${pcm.size / ch} frames @ ${sr}Hz")
        bpmJob = engineScope.launch(Dispatchers.Default) {
            val result = BpmDetector.detect(pcm, sr, ch)
            Log.i(TAG, "BPM detection complete: bpm=${result.bpm.toInt()} confidence=${"%.2f".format(result.confidence)} beats=${result.beats.size}")
            withContext(Dispatchers.Main) {
                onBpmDetected?.invoke(result)
            }
        }
    }

    // ─── Private: state + session wiring ─────────────────────────────────────

    /**
     * Updates [_state] and dispatches [onStateChange] on the main thread.
     * Thread-safe: can be called from the write thread via [engineScope.launch].
     */
    private fun setState(newState: EngineState) {
        _state = newState
        engineScope.launch {
            onStateChange?.invoke(newState)
        }
    }

    /**
     * Connects [AudioSessionManager] callbacks to engine actions.
     * Called once during [init].
     */
    private fun wireSessionCallbacks() {
        sessionManager.onFocusLoss = {
            engineScope.launch {
                stopWriteThread()
                audioTrack?.flush()
                sessionManager.abandonAudioFocus()
                setState(EngineState.Stopped)
            }
        }
        sessionManager.onFocusLossTransient = {
            engineScope.launch {
                if (_state == EngineState.Playing) pause()
            }
        }
        sessionManager.onFocusGain = {
            engineScope.launch {
                if (_state == EngineState.Paused) resume()
            }
        }
        sessionManager.onDuckVolume = { vol ->
            setVolume(vol)
        }
        sessionManager.onRouteChange = { reason ->
            engineScope.launch {
                if (_state == EngineState.Playing) pause()
                onRouteChange?.invoke(reason)
            }
        }
    }
}
