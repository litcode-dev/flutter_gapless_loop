package com.fluttergaplessloop

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Handler
import android.os.Looper
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.io.File

/**
 * Pre-generates a single-bar PCM buffer and loops it via [AudioTrack] MODE_STATIC +
 * [AudioTrack.setLoopPoints] for sample-accurate metronome timing.
 *
 * Beat-tick events (UI hint, ±5 ms jitter) are fired via a [Handler] timer.
 *
 * All public methods must be called from the main thread.
 *
 * @param onBeatTick Called on main thread with beat index (0 = downbeat, 1…N-1 = click).
 * @param onError    Called on main thread with an error message string.
 */
class MetronomeEngine(
    private val onBeatTick: (Int) -> Unit,
    private val onError:    (String) -> Unit
) {

    companion object {
        private const val TAG = "MetronomeEngine"

        /**
         * Builds a bar PCM buffer: accent at frame 0, click at beat positions 1…N-1.
         *
         * The result length is `beatPeriodFrames * beatsPerBar * channelCount` floats.
         * Both click and accent are mixed (summed then clamped to [-1, 1]) into silence.
         * A 5 ms micro-fade is applied at both ends via [AudioFileLoader.applyMicroFade].
         *
         * @param accentPcm    Decoded accent PCM (interleaved floats, normalized [-1, 1]).
         * @param accentFrames Frame count of accent.
         * @param clickPcm     Decoded click PCM (interleaved floats, normalized [-1, 1]).
         * @param clickFrames  Frame count of click.
         * @param sampleRate   Sample rate in Hz.
         * @param channelCount 1 = mono, 2 = stereo.
         * @param bpm          Tempo in beats per minute.
         * @param beatsPerBar  Time signature numerator.
         * @return Interleaved float PCM for one full bar.
         */
        internal fun buildBarBuffer(
            accentPcm:    FloatArray, accentFrames: Int,
            clickPcm:     FloatArray, clickFrames:  Int,
            sampleRate:   Int,        channelCount: Int,
            bpm:          Double,     beatsPerBar:  Int
        ): FloatArray {
            val beatFrames = (sampleRate * 60.0 / bpm).toInt()
            val barFrames  = beatFrames * beatsPerBar
            val bar        = FloatArray(barFrames * channelCount)  // zero-filled

            // Accent at frame 0
            val accentSamples = minOf(accentFrames * channelCount, bar.size)
            for (i in 0 until accentSamples) {
                bar[i] = (bar[i] + accentPcm[i]).coerceIn(-1f, 1f)
            }

            // Click at beat positions 1…beatsPerBar-1
            for (beat in 1 until beatsPerBar) {
                val offset    = beat * beatFrames * channelCount
                val available = bar.size - offset
                if (available <= 0) break
                val clickSamples = minOf(clickFrames * channelCount, available)
                for (i in 0 until clickSamples) {
                    bar[offset + i] = (bar[offset + i] + clickPcm[i]).coerceIn(-1f, 1f)
                }
            }

            // 5 ms micro-fade at both ends to prevent click artefacts on restart
            AudioFileLoader.applyMicroFade(bar, sampleRate, channelCount)
            return bar
        }
    }

    private val scope       = CoroutineScope(Dispatchers.Main + SupervisorJob())
    private val mainHandler = Handler(Looper.getMainLooper())

    private var audioTrack:   AudioTrack? = null
    private var beatRunnable: Runnable?   = null

    // Stored decoded buffers — reused on setBpm / setBeatsPerBar
    private var accentPcm:    FloatArray? = null
    private var accentFrames: Int         = 0
    private var clickPcm:     FloatArray? = null
    private var clickFrames:  Int         = 0
    private var sampleRate:   Int         = 44100
    private var channelCount: Int         = 1

    private var currentBpm:         Double = 120.0
    private var currentBeatsPerBar: Int    = 4
    private var isRunning = false

    // ─── Public API ───────────────────────────────────────────────────────────

    /**
     * Decodes click/accent bytes from temp files and starts the metronome.
     *
     * Runs IO decoding on [Dispatchers.IO] then switches back to main.
     */
    fun start(
        bpm:         Double,
        beatsPerBar: Int,
        clickBytes:  ByteArray,
        accentBytes: ByteArray,
        extension:   String
    ) {
        scope.launch {
            try {
                val click  = decodeFromTempFile(clickBytes,  extension)
                val accent = decodeFromTempFile(accentBytes, extension)

                accentPcm    = accent.pcm
                accentFrames = accent.totalFrames
                clickPcm     = click.pcm
                clickFrames  = click.totalFrames
                sampleRate   = click.sampleRate
                channelCount = click.channelCount

                currentBpm         = bpm
                currentBeatsPerBar = beatsPerBar

                val bar = buildBarBuffer(
                    accentPcm    = accent.pcm, accentFrames = accent.totalFrames,
                    clickPcm     = click.pcm,  clickFrames  = click.totalFrames,
                    sampleRate   = click.sampleRate, channelCount = click.channelCount,
                    bpm          = bpm, beatsPerBar = beatsPerBar
                )
                playBarBuffer(bar, click.sampleRate, click.channelCount)
                startBeatTimer(bpm, beatsPerBar)
                isRunning = true
                Log.i(TAG, "Started: $bpm BPM, $beatsPerBar/4")
            } catch (e: Exception) {
                onError("MetronomeEngine.start failed: ${e.message}")
            }
        }
    }

    /** Stops playback immediately. */
    fun stop() {
        stopBeatTimer()
        releaseAudioTrack()
        isRunning = false
    }

    /** Rebuilds the bar buffer at the new tempo and restarts. No-op if not started. */
    fun setBpm(bpm: Double) {
        if (!isRunning) return
        currentBpm = bpm
        rebuildAndRestart()
    }

    /** Rebuilds the bar buffer with the new time signature and restarts. No-op if not started. */
    fun setBeatsPerBar(beatsPerBar: Int) {
        if (!isRunning) return
        currentBeatsPerBar = beatsPerBar
        rebuildAndRestart()
    }

    /** Releases all resources. */
    fun dispose() {
        stop()
    }

    // ─── Private helpers ─────────────────────────────────────────────────────

    private fun rebuildAndRestart() {
        val aPcm = accentPcm ?: return
        val cPcm = clickPcm  ?: return

        stopBeatTimer()
        releaseAudioTrack()

        val bar = buildBarBuffer(
            accentPcm    = aPcm, accentFrames = accentFrames,
            clickPcm     = cPcm, clickFrames  = clickFrames,
            sampleRate   = sampleRate, channelCount = channelCount,
            bpm          = currentBpm, beatsPerBar = currentBeatsPerBar
        )
        playBarBuffer(bar, sampleRate, channelCount)
        startBeatTimer(currentBpm, currentBeatsPerBar)
    }

    private fun playBarBuffer(bar: FloatArray, sampleRate: Int, channelCount: Int) {
        releaseAudioTrack()

        val barFrames       = bar.size / channelCount
        val bufferSizeBytes = bar.size * 2  // PCM_16BIT = 2 bytes per sample
        val channelMask     = if (channelCount == 1)
            AudioFormat.CHANNEL_OUT_MONO else AudioFormat.CHANNEL_OUT_STEREO

        val track = AudioTrack(
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                .build(),
            AudioFormat.Builder()
                .setSampleRate(sampleRate)
                .setChannelMask(channelMask)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .build(),
            bufferSizeBytes,
            AudioTrack.MODE_STATIC,
            AudioManager.AUDIO_SESSION_ID_GENERATE
        )

        // Convert float [-1,1] → int16 [-32767, 32767]
        val pcmShort = ShortArray(bar.size) { i ->
            (bar[i] * 32767f).toInt().coerceIn(-32768, 32767).toShort()
        }

        track.write(pcmShort, 0, pcmShort.size)
        track.setLoopPoints(0, barFrames, -1)  // -1 = loop forever
        track.play()
        audioTrack = track
    }

    private fun releaseAudioTrack() {
        audioTrack?.let {
            try { it.stop()    } catch (_: Exception) {}
            try { it.release() } catch (_: Exception) {}
        }
        audioTrack = null
    }

    private fun startBeatTimer(bpm: Double, beatsPerBar: Int) {
        stopBeatTimer()
        val beatMs = (60_000.0 / bpm).toLong()
        var beat   = 0

        val runnable = object : Runnable {
            override fun run() {
                onBeatTick(beat)
                beat = (beat + 1) % beatsPerBar
                mainHandler.postDelayed(this, beatMs)
            }
        }
        beatRunnable = runnable
        mainHandler.post(runnable)
    }

    private fun stopBeatTimer() {
        beatRunnable?.let { mainHandler.removeCallbacks(it) }
        beatRunnable = null
    }

    // ─── Byte decoding ────────────────────────────────────────────────────────

    /**
     * Writes [bytes] to a temp file with [extension] and decodes via [AudioFileLoader.decode].
     * The temp file is deleted in a finally block after decoding.
     */
    private suspend fun decodeFromTempFile(bytes: ByteArray, extension: String): AudioFileLoader.DecodedAudio {
        val tmpFile = File.createTempFile("metronome_", ".$extension")
        try {
            tmpFile.writeBytes(bytes)
            return AudioFileLoader.decode(tmpFile.absolutePath)
        } finally {
            try { tmpFile.delete() } catch (_: Exception) {}
        }
    }
}
