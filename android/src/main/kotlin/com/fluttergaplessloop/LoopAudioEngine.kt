package com.fluttergaplessloop

import android.content.Context
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.PlaybackParams
import android.media.audiofx.Equalizer
import android.media.audiofx.PresetReverb
import android.os.Build
import android.os.Process
import android.util.Log
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
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

    /**
     * Invoked when a system audio interruption begins or ends.
     * Argument is `"began"` or `"ended"`. Always called on the main thread.
     */
    var onInterruption: ((String) -> Unit)? = null

    /**
     * Invoked after [seek] updates the frame position.
     * Argument is the actual seek position in seconds. Always called on the main thread.
     */
    var onSeekComplete: ((Double) -> Unit)? = null

    /**
     * Invoked with (magnitudes, sampleRate) FFT spectrum data approximately 10 times per second
     * while the engine is playing. magnitudes is 256 normalised values in [0,1].
     * Always called on the main thread.
     */
    var onSpectrum: ((FloatArray, Double) -> Unit)? = null

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

    /** Last time (ms) a spectrum event was dispatched. Throttles to ~10 Hz. */
    @Volatile private var lastSpectrumTimeMs: Long = 0

    // ─── Tier 3: AudioFx effects ─────────────────────────────────────────────

    /** Android Equalizer effect bound to the AudioTrack session. */
    private var equalizer: Equalizer? = null

    /** Android PresetReverb effect bound to the AudioTrack session. */
    private var presetReverb: PresetReverb? = null

    // Compressor state (pure software, applied per write chunk)
    @Volatile private var compressorEnabled    = false
    @Volatile private var compressorThreshold  = 0.25f   // linear, default -12 dBFS
    @Volatile private var compressorMakeupGain = 1.0f
    @Volatile private var compressorAttack     = 0.9f    // 1-frame coefficient
    @Volatile private var compressorRelease    = 0.999f  // 1-frame coefficient
    @Volatile private var compressorEnvelope   = 0f      // per-write-thread envelope follower

    // Pre-allocated 1024-sample Hann window + FFT workspace (write thread only)
    private val hannWindow   = FloatArray(1024) { i ->
        (0.5f * (1f - kotlin.math.cos(2.0 * Math.PI * i / 1023).toFloat()))
    }
    private val fftWorkBuf   = FloatArray(1024)  // mono mix + Hann applied

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
        applyPlaybackParams()
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

    /** Backing field for [setPlaybackRate]. Written from main thread; read by [applyPlaybackParams]. */
    @Volatile private var playbackRate: Float = 1f

    /** Backing field for [setPitch]. Written from main thread; read by [applyPlaybackParams]. */
    @Volatile private var pitchSemitones: Float = 0f

    /**
     * Sets the playback rate (speed) while preserving pitch.
     * [rate] is a multiplier: 1.0 = normal, 2.0 = double speed, 0.5 = half speed.
     * Uses [AudioTrack.setPlaybackParams] on API 23+. No-op on older devices.
     * Called on the main thread. Thread-safe via @Volatile.
     */
    fun setPlaybackRate(rate: Float) {
        playbackRate = rate.coerceIn(0.25f, 4.0f)
        applyPlaybackParams()
    }

    /**
     * Shifts the pitch by [semitones] without changing playback speed.
     *
     * `0.0` = no shift (default). Range: −24.0 to +24.0 semitones (±2 octaves).
     * Converts to a linear pitch multiplier via `2^(semitones/12)` and applies via
     * [PlaybackParams.setPitch] on API 23+. No-op on older devices.
     *
     * This is fully independent of [setPlaybackRate] — both are applied together
     * in a single [PlaybackParams] object so neither overrides the other.
     */
    fun setPitch(semitones: Float) {
        pitchSemitones = semitones.coerceIn(-24f, 24f)
        applyPlaybackParams()
    }

    /**
     * Applies the current [playbackRate] and [pitchSemitones] to the [AudioTrack]
     * in a single [PlaybackParams] call so they never override each other.
     */
    private fun applyPlaybackParams() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val pitchFactor = Math.pow(2.0, (pitchSemitones / 12.0).toDouble()).toFloat()
            audioTrack?.playbackParams = PlaybackParams()
                .setSpeed(playbackRate)
                .setPitch(pitchFactor)
        }
    }

    // ─── Tier 3: Effects API ──────────────────────────────────────────────────

    /**
     * Sets the 3-band EQ gains in dB.
     *
     * Maps to the three closest Android [Equalizer] bands:
     * - bass   → lowest available band (≤200 Hz)
     * - mid    → band nearest 1000 Hz
     * - treble → highest available band (≥4000 Hz)
     *
     * Gain is clamped to [-12, +12] dB. No-op if the Equalizer is unavailable.
     */
    fun setEq(bassDb: Float, midDb: Float, trebleDb: Float) {
        val eq = equalizer ?: return
        try {
            val nBands = eq.numberOfBands.toInt()
            if (nBands < 1) return

            // Android Equalizer uses milli-Bell (10ths of dB) units.
            fun dbToMb(db: Float) = (db.coerceIn(-12f, 12f) * 100).toInt().toShort()

            // Find indices for bass (lowest), mid (nearest 1kHz), treble (highest).
            val bassBandIdx   = 0
            val trebleBandIdx = nBands - 1
            var midBandIdx    = nBands / 2
            var bestMidDist   = Long.MAX_VALUE
            for (i in 0 until nBands) {
                val centerHz = eq.getBandFreqRange(i.toShort())[0] / 1000 // milliHz → Hz
                val dist = kotlin.math.abs(centerHz - 1_000_000L)
                if (dist < bestMidDist) { bestMidDist = dist; midBandIdx = i }
            }

            eq.setBandLevel(bassBandIdx.toShort(),   dbToMb(bassDb))
            eq.setBandLevel(midBandIdx.toShort(),    dbToMb(midDb))
            eq.setBandLevel(trebleBandIdx.toShort(), dbToMb(trebleDb))
            eq.enabled = true
        } catch (e: Exception) {
            Log.w(TAG, "setEq failed: ${e.message}")
        }
    }

    /**
     * Applies a reverb preset with a wet-mix percentage.
     *
     * [preset] is the iOS-compatible preset name ("none", "smallRoom", etc.).
     * [wetMix] is in [0.0, 1.0]; 0.0 disables the effect.
     *
     * Android [PresetReverb] does not support a wet/dry mix — the effect is on/off.
     * A wetMix of 0 or preset "none" disables the effect.
     */
    fun setReverb(preset: String, wetMix: Float) {
        val rv = presetReverb ?: return
        try {
            if (preset == "none" || wetMix <= 0f) {
                rv.enabled = false
                return
            }
            val androidPreset: Short = when (preset) {
                "smallRoom"  -> PresetReverb.PRESET_SMALLROOM
                "mediumRoom" -> PresetReverb.PRESET_MEDIUMROOM
                "largeRoom"  -> PresetReverb.PRESET_LARGEROOM
                "mediumHall" -> PresetReverb.PRESET_MEDIUMHALL
                "largeHall"  -> PresetReverb.PRESET_LARGEHALL
                "plate"      -> PresetReverb.PRESET_PLATE
                "cathedral"  -> PresetReverb.PRESET_LARGEHALL  // best match
                else         -> PresetReverb.PRESET_NONE
            }
            rv.preset  = androidPreset
            rv.enabled = androidPreset != PresetReverb.PRESET_NONE
        } catch (e: Exception) {
            Log.w(TAG, "setReverb failed: ${e.message}")
        }
    }

    /**
     * Configures the software compressor/limiter applied per write chunk.
     *
     * Parameters are converted to per-sample attack/release coefficients using
     * the standard 1-pole IIR formula: coeff = exp(-1 / (ms/1000 * sampleRate)).
     *
     * A ratio of ∞:1 (hard limiter) is used above [thresholdDb] for simplicity.
     */
    fun setCompressor(
        enabled:      Boolean,
        thresholdDb:  Float,
        makeupGainDb: Float,
        attackMs:     Float,
        releaseMs:    Float
    ) {
        compressorEnabled    = enabled
        compressorThreshold  = Math.pow(10.0, (thresholdDb.coerceIn(-40f, 0f) / 20.0)).toFloat()
        compressorMakeupGain = Math.pow(10.0, (makeupGainDb.coerceIn(-20f, 20f) / 20.0)).toFloat()
        val sr = sampleRate.toDouble()
        compressorAttack  = if (attackMs  <= 0f) 0f else
            Math.exp(-1.0 / (attackMs  / 1000.0 * sr)).toFloat()
        compressorRelease = if (releaseMs <= 0f) 0f else
            Math.exp(-1.0 / (releaseMs / 1000.0 * sr)).toFloat()
    }

    /**
     * Exports the current loop region (or full file if no region set) as a 32-bit float WAV.
     *
     * Runs on [Dispatchers.IO]. [onComplete] is called on the main thread with
     * `null` on success or an exception on failure.
     */
    fun exportToFile(outputPath: String, onComplete: (Exception?) -> Unit) {
        val pcm = pcmBuffer
        if (pcm == null) {
            engineScope.launch { onComplete(IllegalStateException("No audio loaded")) }
            return
        }
        val startFrame = loopStartFrame
        val endFrame   = loopEndFrame
        val sr         = sampleRate
        val ch         = channelCount

        engineScope.launch(Dispatchers.IO) {
            try {
                writeWavFile(
                    path       = outputPath,
                    pcm        = pcm,
                    startFrame = startFrame,
                    endFrame   = endFrame,
                    sampleRate = sr,
                    channels   = ch
                )
                withContext(Dispatchers.Main) { onComplete(null) }
            } catch (e: Exception) {
                Log.e(TAG, "exportToFile failed: ${e.message}", e)
                withContext(Dispatchers.Main) { onComplete(e) }
            }
        }
    }

    /**
     * Writes [pcm] samples from [startFrame] to [endFrame] as a 32-bit float WAV file.
     */
    private fun writeWavFile(
        path: String, pcm: FloatArray,
        startFrame: Int, endFrame: Int,
        sampleRate: Int, channels: Int
    ) {
        val numFrames  = endFrame - startFrame
        val numSamples = numFrames * channels
        val dataBytes  = numSamples * 4  // 4 bytes per float32 sample

        val file = File(path)
        file.parentFile?.mkdirs()

        RandomAccessFile(file, "rw").use { raf ->
            // WAV header (44 bytes)
            val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
            header.put("RIFF".toByteArray())
            header.putInt(36 + dataBytes)         // chunk size
            header.put("WAVE".toByteArray())
            header.put("fmt ".toByteArray())
            header.putInt(16)                     // subchunk size
            header.putShort(3)                    // PCM float = 3
            header.putShort(channels.toShort())
            header.putInt(sampleRate)
            header.putInt(sampleRate * channels * 4)  // byte rate
            header.putShort((channels * 4).toShort())  // block align
            header.putShort(32)                   // bits per sample
            header.put("data".toByteArray())
            header.putInt(dataBytes)
            raf.write(header.array())

            // PCM data — write in 8 kB chunks to avoid large heap allocation
            val chunkSamples = 2048
            val chunkBytes   = ByteBuffer.allocate(chunkSamples * 4).order(ByteOrder.LITTLE_ENDIAN)
            var srcOffset    = startFrame * channels
            var remaining    = numSamples
            while (remaining > 0) {
                val n = minOf(remaining, chunkSamples)
                chunkBytes.clear()
                for (i in 0 until n) chunkBytes.putFloat(pcm[srcOffset + i])
                raf.write(chunkBytes.array(), 0, n * 4)
                srcOffset += n
                remaining -= n
            }
        }
        Log.i(TAG, "exportToFile: wrote $numFrames frames to $path")
    }

    // ─── Private: fade coroutine ──────────────────────────────────────────────

    /** Currently running fade job. Cancelled on each new [fadeTo] call. */
    private var fadeJob: Job? = null

    /** User-visible "local" volume, maintained so fade targets are consistent. */
    @Volatile private var userVolume: Float = 1f

    /**
     * Ramps the [AudioTrack] software gain from its current level to [targetVolume]
     * over [durationMs] milliseconds.
     *
     * The ramp runs in a coroutine on [engineScope] (~100 Hz update rate via `delay`).
     * Pass [startFromSilence] = true to immediately zero the volume before ramping up.
     */
    fun fadeTo(targetVolume: Float, durationMs: Long, startFromSilence: Boolean = false) {
        val from = if (startFromSilence) {
            audioTrack?.setVolume(0f)
            0f
        } else {
            userVolume
        }
        val to = targetVolume.coerceIn(0f, 1f)
        userVolume = to

        fadeJob?.cancel()
        fadeJob = engineScope.launch {
            if (durationMs <= 0L) {
                audioTrack?.setVolume(to)
                return@launch
            }
            val stepMs    = 10L          // ~100 Hz
            val totalSteps = (durationMs / stepMs).toInt().coerceAtLeast(1)
            for (step in 1..totalSteps) {
                val t   = step.toFloat() / totalSteps.toFloat()
                val vol = from + (to - from) * t
                audioTrack?.setVolume(vol.coerceIn(0f, 1f))
                kotlinx.coroutines.delay(stepMs)
            }
            audioTrack?.setVolume(to)
        }
    }

    // ─── Public: Waveform / Analysis ─────────────────────────────────────────

    /**
     * Returns a downsampled peak-amplitude array with [resolution] data points.
     *
     * Each point is the maximum absolute sample magnitude in its segment, in [0, 1].
     * Runs synchronously on the calling thread (expected to be called from a coroutine
     * on [Dispatchers.Default]).
     */
    fun getWaveformData(resolution: Int): FloatArray {
        val buf = pcmBuffer ?: return FloatArray(0)
        val r   = resolution.coerceIn(2, 8192)
        val peaks = FloatArray(r)
        val segFrames = totalFrames / r
        for (seg in 0 until r) {
            val startFrame = seg * segFrames
            val endFrame   = if (seg == r - 1) totalFrames else startFrame + segFrames
            var peak = 0f
            for (frame in startFrame until endFrame) {
                for (ch in 0 until channelCount) {
                    val s = buf[frame * channelCount + ch]
                    val abs = if (s < 0f) -s else s
                    if (abs > peak) peak = abs
                }
            }
            peaks[seg] = peak.coerceIn(0f, 1f)
        }
        return peaks
    }

    /**
     * Scans the loaded file for silence below [thresholdDb] dBFS and returns
     * the start and end of the non-silent region in seconds.
     *
     * If the entire file is below threshold, returns (0.0, duration).
     */
    fun detectSilence(thresholdDb: Float): Pair<Double, Double> {
        val buf = pcmBuffer ?: return Pair(0.0, duration)
        val threshold = Math.pow(10.0, thresholdDb / 20.0).toFloat()

        fun isAudible(frame: Int): Boolean {
            for (ch in 0 until channelCount) {
                val s = buf[frame * channelCount + ch]
                if ((if (s < 0f) -s else s) >= threshold) return true
            }
            return false
        }

        var startFrame = 0
        for (i in 0 until totalFrames) {
            if (isAudible(i)) { startFrame = i; break }
        }
        var endFrame = totalFrames - 1
        for (i in totalFrames - 1 downTo 0) {
            if (isAudible(i)) { endFrame = i; break }
        }

        return Pair(
            startFrame.toDouble() / sampleRate.toDouble(),
            (endFrame + 1).toDouble() / sampleRate.toDouble()
        )
    }

    /**
     * Computes integrated loudness in LUFS using EBU R128 K-weighting.
     * Returns -100.0 if no file is loaded or the file is silent.
     */
    fun getLoudness(): Double {
        val buf = pcmBuffer ?: return -100.0
        return LoudnessAnalyser.analyse(buf, sampleRate, channelCount)
    }

    /**
     * Starts playback at a future wall-clock time [targetUptimeMs] (from
     * [android.os.SystemClock.uptimeMillis]).
     *
     * The write thread sleeps until [targetUptimeMs] before writing its first
     * chunk, ensuring sample-accurate alignment with other players that receive
     * the same target time.
     */
    fun syncPlay(targetUptimeMs: Long) {
        if (_state != EngineState.Ready && _state != EngineState.Stopped) {
            Log.w(TAG, "syncPlay() ignored: state=$_state")
            return
        }
        if (!sessionManager.requestAudioFocus()) {
            onError?.invoke(LoopEngineError.AudioFocusDenied("AudioManager denied AUDIOFOCUS_GAIN"))
            return
        }
        currentFrameAtomic.set(loopStartFrame.toLong())
        audioTrack?.play()
        applyPlaybackParams()
        startSyncWriteThread(targetUptimeMs)
        setState(EngineState.Playing)
    }

    /** Like [startWriteThread] but sleeps until [targetUptimeMs] before writing. */
    private fun startSyncWriteThread(targetUptimeMs: Long) {
        stopRequested      = false
        pauseRequested     = false
        lastAmplitudeTimeMs = 0
        lastSpectrumTimeMs  = 0
        compressorEnvelope  = 0f

        writeThread = Thread {
            Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)

            // Sleep until the target time.
            val nowMs = android.os.SystemClock.uptimeMillis()
            val sleepMs = targetUptimeMs - nowMs
            if (sleepMs > 0) {
                try { Thread.sleep(sleepMs) } catch (_: InterruptedException) {}
            }

            // Delegate to the normal write loop by calling startWriteThread's inner logic.
            // We reuse the write logic by immediately delegating after the sleep.
            val track = audioTrack ?: return@Thread
            val buffer = pcmBuffer ?: return@Thread
            val chunkFrames  = track.bufferSizeInFrames / 2
            val chunkSamples = chunkFrames * channelCount
            val writeBuffer  = FloatArray(chunkSamples)

            try {
                while (!stopRequested) {
                    if (pauseRequested) {
                        try { pauseSemaphore.acquire() } catch (e: InterruptedException) { break }
                        if (stopRequested) break
                        continue
                    }

                    val region      = loopRegionRef.get()
                    val regionStart = region.start
                    val regionEnd   = region.end
                    var currentFrame = currentFrameAtomic.get().toInt()

                    var writeIdx = 0
                    while (writeIdx < chunkSamples && !stopRequested && !pauseRequested) {
                        if (currentFrame >= regionEnd) {
                            val cfBlock = crossfadeBlockRef.get()
                            if (cfBlock != null && writeIdx + cfBlock.size <= chunkSamples) {
                                cfBlock.copyInto(writeBuffer, writeIdx)
                                writeIdx += cfBlock.size
                            }
                            currentFrame = regionStart
                        }
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

                    if (writeIdx > 0) {
                        applyCompressor(writeBuffer, writeIdx)
                        val written = track.write(writeBuffer, 0, writeIdx, AudioTrack.WRITE_BLOCKING)
                        if (written < 0) {
                            val err = LoopEngineError.AudioTrackError(written)
                            engineScope.launch { setState(EngineState.Error(err)); onError?.invoke(err) }
                            break
                        }
                        val amplitudeCallback = onAmplitude
                        if (amplitudeCallback != null) {
                            val nowMs2 = System.currentTimeMillis()
                            if (nowMs2 - lastAmplitudeTimeMs >= 50) {
                                lastAmplitudeTimeMs = nowMs2
                                var sumSq = 0f; var peak = 0f
                                for (i in 0 until writeIdx) {
                                    val s = writeBuffer[i]
                                    sumSq += s * s
                                    val abs = if (s < 0f) -s else s
                                    if (abs > peak) peak = abs
                                }
                                val rms = kotlin.math.sqrt(sumSq / writeIdx)
                                engineScope.launch { amplitudeCallback(rms.coerceIn(0f,1f), peak.coerceIn(0f,1f)) }
                            }
                        }
                        val spectrumCallback2 = onSpectrum
                        if (spectrumCallback2 != null) {
                            val spectrum2 = computeSpectrum(writeBuffer, writeIdx, channelCount)
                            if (spectrum2 != null) {
                                val sr = sampleRate.toDouble()
                                engineScope.launch { spectrumCallback2(spectrum2, sr) }
                            }
                        }
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "SyncWrite thread exception: ${e.message}", e)
            }
        }
        writeThread?.isDaemon = true
        writeThread?.start()
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
        val actualPosition = targetFrame.toDouble() / sampleRate.toDouble()
        engineScope.launch { onSeekComplete?.invoke(actualPosition) }
        Log.i(TAG, "seek: ${seconds}s → frame $targetFrame")
    }

    /**
     * Releases all resources. After this call the engine must not be reused.
     */
    fun dispose() {
        stopWriteThread()
        sessionManager.dispose()
        equalizer?.release();    equalizer   = null
        presetReverb?.release(); presetReverb = null
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
        applyPan()
        applyPlaybackParams()
        reattachEffects()
    }

    /**
     * Releases and re-creates [Equalizer] and [PresetReverb] bound to the new [audioTrack]
     * session ID. Must be called every time [buildAudioTrack] creates a new [AudioTrack]
     * because effects are bound to a specific session at construction time.
     */
    private fun reattachEffects() {
        val track = audioTrack ?: return
        val sessionId = track.audioSessionId

        // Equalizer
        try {
            equalizer?.release()
            equalizer = Equalizer(0, sessionId).also { eq ->
                eq.enabled = true
                // Store current band gains to reapply (they reset to 0 when re-created)
            }
        } catch (e: Exception) {
            Log.w(TAG, "Equalizer init failed: ${e.message}")
            equalizer = null
        }

        // PresetReverb
        try {
            presetReverb?.release()
            presetReverb = PresetReverb(0, sessionId).also { rv ->
                rv.preset = PresetReverb.PRESET_NONE
                rv.enabled = false
            }
        } catch (e: Exception) {
            Log.w(TAG, "PresetReverb init failed: ${e.message}")
            presetReverb = null
        }
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
        stopRequested       = false
        pauseRequested      = false
        lastAmplitudeTimeMs = 0
        lastSpectrumTimeMs  = 0
        compressorEnvelope  = 0f

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
                        // ── Apply software compressor before write ──────────────
                        applyCompressor(writeBuffer, writeIdx)

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

                        // ── Spectrum FFT (~10 Hz) ──────────────────────────────
                        val spectrumCallback = onSpectrum
                        if (spectrumCallback != null) {
                            val spectrum = computeSpectrum(writeBuffer, writeIdx, channelCount)
                            if (spectrum != null) {
                                val sr = sampleRate.toDouble()
                                engineScope.launch { spectrumCallback(spectrum, sr) }
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

    // ─── Private: Cooley-Tukey FFT ────────────────────────────────────────────

    /**
     * In-place iterative Cooley-Tukey radix-2 DIT FFT.
     *
     * @param re Real parts array. Size must be a power of 2.
     * @param im Imaginary parts array, same size as [re]. Typically all zeros for real input.
     *
     * After this call, re[k] and im[k] contain the real and imaginary parts of bin k.
     * Only the first N/2 bins are useful for real-input FFT (mirrored above N/2).
     */
    private fun fft(re: FloatArray, im: FloatArray) {
        val n = re.size
        // Bit-reversal permutation
        var j = 0
        for (i in 1 until n) {
            var bit = n shr 1
            while (j and bit != 0) { j = j xor bit; bit = bit shr 1 }
            j = j xor bit
            if (i < j) {
                var t = re[i]; re[i] = re[j]; re[j] = t
                t = im[i]; im[i] = im[j]; im[j] = t
            }
        }
        // Danielson-Lanczos butterfly
        var len = 2
        while (len <= n) {
            val ang = (-2.0 * Math.PI / len).toFloat()
            val wRe = kotlin.math.cos(ang.toDouble()).toFloat()
            val wIm = kotlin.math.sin(ang.toDouble()).toFloat()
            var i = 0
            while (i < n) {
                var curRe = 1f; var curIm = 0f
                for (k in 0 until len / 2) {
                    val uRe = re[i + k];          val uIm = im[i + k]
                    val vRe = re[i + k + len / 2]; val vIm = im[i + k + len / 2]
                    val tRe = curRe * vRe - curIm * vIm
                    val tIm = curRe * vIm + curIm * vRe
                    re[i + k]          = uRe + tRe; im[i + k]          = uIm + tIm
                    re[i + k + len / 2] = uRe - tRe; im[i + k + len / 2] = uIm - tIm
                    val nextRe = curRe * wRe - curIm * wIm
                    curIm      = curRe * wIm + curIm * wRe
                    curRe      = nextRe
                }
                i += len
            }
            len = len shl 1
        }
    }

    /**
     * Applies the software compressor to [buf] in-place (first [count] samples).
     * No-op if [compressorEnabled] is false.
     */
    private fun applyCompressor(buf: FloatArray, count: Int) {
        if (!compressorEnabled) return
        val threshold  = compressorThreshold
        val makeupGain = compressorMakeupGain
        val atk        = compressorAttack
        val rel        = compressorRelease
        var env        = compressorEnvelope
        for (i in 0 until count) {
            val absS = if (buf[i] < 0f) -buf[i] else buf[i]
            env = if (absS > env) atk * env + (1f - atk) * absS
                  else            rel * env + (1f - rel) * absS
            val gain = if (env > threshold) threshold / env else 1f
            buf[i] = buf[i] * gain * makeupGain
        }
        compressorEnvelope = env
    }

    /**
     * Computes a 256-bin FFT magnitude spectrum from the first [count] samples of [buf]
     * (interleaved [channels] channels), throttled to ~10 Hz.
     *
     * Returns null if not enough time has elapsed since [lastSpectrumTimeMs].
     */
    private fun computeSpectrum(buf: FloatArray, count: Int, channels: Int): FloatArray? {
        val nowMs = System.currentTimeMillis()
        if (nowMs - lastSpectrumTimeMs < 100) return null
        lastSpectrumTimeMs = nowMs

        val n        = minOf(count, 1024)
        val fftRe    = fftWorkBuf   // re-use pre-allocated buffer
        val fftIm    = FloatArray(1024)

        // Mix to mono, apply Hann window
        for (i in 0 until n) {
            var s = 0f
            val base = i * channels
            for (ch in 0 until channels) s += if (base + ch < buf.size) buf[base + ch] else 0f
            fftRe[i] = s / channels * hannWindow[i]
            fftIm[i] = 0f
        }
        for (i in n until 1024) { fftRe[i] = 0f; fftIm[i] = 0f }

        fft(fftRe, fftIm)

        // Average adjacent bins into 256 output bins (from first 512 bins)
        val out = FloatArray(256)
        for (i in 0 until 256) {
            val mag0 = kotlin.math.sqrt((fftRe[i*2].toDouble().let { it*it } + fftIm[i*2].toDouble().let { it*it })) / 512.0
            val mag1 = kotlin.math.sqrt((fftRe[i*2+1].toDouble().let { it*it } + fftIm[i*2+1].toDouble().let { it*it })) / 512.0
            out[i] = ((mag0 + mag1) * 0.5).coerceIn(0.0, 1.0).toFloat()
        }
        return out
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
    /**
     * Re-triggers BPM detection on the currently loaded buffer.
     *
     * The result is dispatched via [onBpmDetected] exactly as after a load.
     * Does nothing if no buffer is loaded.
     */
    fun reanalyzeBpm() {
        if (pcmBuffer == null) return
        bpmJob?.cancel()
        launchBpmDetection()
    }

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
                if (_state == EngineState.Playing) {
                    pause()
                    onInterruption?.invoke("began")
                }
            }
        }
        sessionManager.onFocusGain = {
            engineScope.launch {
                if (_state == EngineState.Paused) {
                    resume()
                    onInterruption?.invoke("ended")
                }
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
