package com.fluttergaplessloop

import android.content.res.AssetFileDescriptor
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.util.Log
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Decodes audio files to a normalized [FloatArray] using [MediaExtractor] and [MediaCodec].
 *
 * Supports any container/codec recognized by the Android MediaCodec framework:
 * MP3, AAC, FLAC, OGG/Vorbis, WAV (PCM). Format is detected automatically from
 * the MIME type exposed by [MediaExtractor.getTrackFormat].
 *
 * Decoded PCM is always float, normalized to the range [-1.0, 1.0]:
 * - PCM_16BIT output: `floatSample = shortSample / 32768.0f`
 * - PCM_FLOAT output: passed through unchanged
 *
 * All operations run on [Dispatchers.IO]. Never call from the main thread.
 */
object AudioFileLoader {

    private const val TAG = "AudioFileLoader"

    /**
     * Decoded audio data plus metadata needed to configure [AudioTrack] and the write thread.
     *
     * @param pcm          Interleaved float samples, normalized [-1.0, 1.0].
     *                     Length = [totalFrames] * [channelCount].
     * @param sampleRate   Sample rate in Hz (e.g. 44100, 48000).
     * @param channelCount Number of channels (1 = mono, 2 = stereo).
     * @param totalFrames  Total audio frames: `pcm.size / channelCount`.
     */
    data class DecodedAudio(
        val pcm: FloatArray,
        val sampleRate: Int,
        val channelCount: Int,
        val totalFrames: Int
    )

    /**
     * Decodes the audio file at [path] to [DecodedAudio].
     *
     * Suspends on [Dispatchers.IO] — safe to call from a coroutine scope on any thread.
     * Never call from the main thread directly.
     *
     * @param path       Absolute filesystem path to the audio file.
     * @param onProgress Optional progress callback, values in [0.0, 1.0].
     * @throws LoopAudioException wrapping [LoopEngineError.FileNotFound] if file missing.
     * @throws LoopAudioException wrapping [LoopEngineError.UnsupportedFormat] if no audio track.
     * @throws LoopAudioException wrapping [LoopEngineError.DecodeFailed] on codec errors.
     */
    suspend fun decode(
        path: String,
        onProgress: ((Float) -> Unit)? = null
    ): DecodedAudio = withContext(Dispatchers.IO) {
        if (!File(path).exists()) {
            throw LoopAudioException(LoopEngineError.FileNotFound(path))
        }
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(path)
            decodeFromExtractor(extractor, onProgress)
        } finally {
            try { extractor.release() } catch (_: Exception) {}
        }
    }

    /**
     * Decodes an audio asset exposed via [assetFd] (from `context.assets.openFd()`).
     *
     * Used by the `loadAsset` method channel handler to read Flutter bundled assets
     * without extracting them to the filesystem first.
     *
     * @param assetFd    [AssetFileDescriptor] obtained from the Flutter asset registry.
     * @param onProgress Optional progress callback.
     * @throws LoopAudioException on decode failure.
     */
    suspend fun decodeAsset(
        assetFd: AssetFileDescriptor,
        onProgress: ((Float) -> Unit)? = null
    ): DecodedAudio = withContext(Dispatchers.IO) {
        val extractor = MediaExtractor()
        try {
            // offset + declaredLength required for assets embedded inside the APK
            extractor.setDataSource(
                assetFd.fileDescriptor,
                assetFd.startOffset,
                assetFd.declaredLength
            )
            decodeFromExtractor(extractor, onProgress)
        } finally {
            try { extractor.release() } catch (_: Exception) {}
        }
    }

    /**
     * Applies a 5 ms linear micro-fade in-place at both ends of [pcm].
     *
     * Eliminates clicks at the loop boundary by ramping amplitude from 0 to full
     * over the first 5 ms and from full to 0 over the last 5 ms. Applied once at
     * load time — never during playback.
     *
     * Formula:
     * ```
     * fadeFrames = (sampleRate * 0.005).toInt()
     * fade-in:  pcm[i*ch+c]               *= i.toFloat() / fadeFrames
     * fade-out: pcm[(totalFrames-1-i)*ch+c] *= i.toFloat() / fadeFrames
     * ```
     */
    fun applyMicroFade(pcm: FloatArray, sampleRate: Int, channelCount: Int) {
        val fadeFrames = (sampleRate * 0.005).toInt().coerceAtLeast(1)
        val totalFrames = pcm.size / channelCount
        for (i in 0 until fadeFrames) {
            val gain = i.toFloat() / fadeFrames.toFloat()
            // Fade in: ramp amplitude from 0 to 1 over the first N frames
            for (ch in 0 until channelCount) {
                pcm[i * channelCount + ch] *= gain
            }
            // Fade out: ramp amplitude from 1 to 0 over the last N frames
            val endFrame = totalFrames - 1 - i
            if (endFrame > i) {   // Guard: skip overlap when file < 2×fadeFrames
                for (ch in 0 until channelCount) {
                    pcm[endFrame * channelCount + ch] *= gain
                }
            }
        }
    }

    // ─── Private helpers ────────────────────────────────────────────────────

    /**
     * Core decode implementation shared by [decode] and [decodeAsset].
     *
     * Uses [MediaCodec] in async callback mode so codec buffer callbacks fire
     * immediately instead of being gated by a polling timeout. A pre-allocated
     * [FloatArray] (sized from the track duration estimate + 10% headroom) is
     * grown with a 1.25× reallocation factor if needed, eliminating the
     * intermediate ArrayList<FloatArray> and the final concat copy.
     *
     * MediaCodec guarantees that [MediaCodec.Callback] methods are serialized,
     * so the mutable state (pcm, totalSamples, outputFormat) needs no external
     * synchronization.
     *
     * @throws LoopAudioException on any codec failure.
     */
    private suspend fun decodeFromExtractor(
        extractor: MediaExtractor,
        onProgress: ((Float) -> Unit)?
    ): DecodedAudio {
        val trackIndex = findAudioTrack(extractor)
            ?: throw LoopAudioException(
                LoopEngineError.UnsupportedFormat("No audio track found in file")
            )
        extractor.selectTrack(trackIndex)

        val format       = extractor.getTrackFormat(trackIndex)
        val mime         = format.getString(MediaFormat.KEY_MIME)
            ?: throw LoopAudioException(LoopEngineError.UnsupportedFormat("null MIME type"))
        val sampleRate   = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        val channelCount = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)

        val durationUs = if (format.containsKey(MediaFormat.KEY_DURATION))
            format.getLong(MediaFormat.KEY_DURATION) else 0L
        val estFrames  = ((durationUs / 1_000_000.0) * sampleRate).toInt().coerceAtLeast(1)

        Log.i(TAG, "Decoding: mime=$mime rate=$sampleRate ch=$channelCount ~$estFrames frames")

        // Pre-allocate with 10% headroom for encoder padding/priming frames.
        var pcm          = FloatArray((estFrames * channelCount * 1.1).toInt())
        var totalSamples = 0
        var outputFormat = format

        val deferred = CompletableDeferred<DecodedAudio>()
        val codec    = MediaCodec.createDecoderByType(mime)

        codec.setCallback(object : MediaCodec.Callback() {
            override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {
                val inBuf = codec.getInputBuffer(index) ?: return
                val sampleSize = extractor.readSampleData(inBuf, 0)
                if (sampleSize < 0) {
                    codec.queueInputBuffer(index, 0, 0, 0L, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                } else {
                    codec.queueInputBuffer(index, 0, sampleSize, extractor.sampleTime, 0)
                    extractor.advance()
                }
            }

            override fun onOutputBufferAvailable(
                codec: MediaCodec,
                index: Int,
                info: MediaCodec.BufferInfo
            ) {
                val outBuf = codec.getOutputBuffer(index)
                if (outBuf != null && info.size > 0) {
                    // Worst-case sample count: info.size / 2 (16-bit shorts)
                    val needed = totalSamples + info.size / 2
                    if (needed > pcm.size) {
                        pcm = pcm.copyOf((needed * 1.25).toInt())
                    }
                    totalSamples += extractFloatChunkInto(outBuf, info, outputFormat, pcm, totalSamples)
                    if (durationUs > 0 && onProgress != null) {
                        onProgress((totalSamples / channelCount).toFloat() / estFrames.toFloat())
                    }
                }
                codec.releaseOutputBuffer(index, false)
                if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                    val finalPcm    = if (totalSamples == pcm.size) pcm else pcm.copyOf(totalSamples)
                    val totalFrames = totalSamples / channelCount
                    Log.i(TAG, "Decode complete: $totalFrames frames, ${sampleRate}Hz, ${channelCount}ch")
                    deferred.complete(DecodedAudio(finalPcm, sampleRate, channelCount, totalFrames))
                }
            }

            override fun onError(codec: MediaCodec, e: MediaCodec.CodecException) {
                deferred.completeExceptionally(
                    LoopAudioException(LoopEngineError.DecodeFailed(e.message ?: "codec error"))
                )
            }

            override fun onOutputFormatChanged(codec: MediaCodec, newFormat: MediaFormat) {
                outputFormat = newFormat
                Log.d(TAG, "Output format changed: $newFormat")
            }
        })

        codec.configure(format, null, null, 0)
        codec.start()

        try {
            return deferred.await()
        } finally {
            try { codec.stop()    } catch (_: Exception) {}
            try { codec.release() } catch (_: Exception) {}
        }
    }

    /** Returns the index of the first audio track in [extractor], or null if none found. */
    private fun findAudioTrack(extractor: MediaExtractor): Int? {
        for (i in 0 until extractor.trackCount) {
            val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: continue
            if (mime.startsWith("audio/")) return i
        }
        return null
    }

    /**
     * Extracts samples from [outBuf] and writes normalized floats [-1.0, 1.0] directly
     * into [dest] starting at [offset]. Returns the number of samples written.
     *
     * Handles PCM_16BIT (most common) and PCM_FLOAT codec output.
     * Encoding is detected from [format]'s KEY_PCM_ENCODING, defaulting to PCM_16BIT.
     */
    private fun extractFloatChunkInto(
        outBuf: ByteBuffer,
        bufInfo: MediaCodec.BufferInfo,
        format: MediaFormat,
        dest: FloatArray,
        offset: Int
    ): Int {
        outBuf.position(bufInfo.offset)
        outBuf.limit(bufInfo.offset + bufInfo.size)

        val encoding = if (format.containsKey(MediaFormat.KEY_PCM_ENCODING))
            format.getInteger(MediaFormat.KEY_PCM_ENCODING)
        else
            AudioFormat.ENCODING_PCM_16BIT

        return when (encoding) {
            AudioFormat.ENCODING_PCM_FLOAT -> {
                val buf   = outBuf.order(ByteOrder.nativeOrder()).asFloatBuffer()
                val count = buf.remaining()
                buf.get(dest, offset, count)
                count
            }
            else -> {
                // PCM_16BIT: normalize by dividing by 32768 to get [-1.0, 1.0]
                val buf   = outBuf.order(ByteOrder.nativeOrder()).asShortBuffer()
                val count = buf.remaining()
                for (i in 0 until count) {
                    dest[offset + i] = buf.get() / 32768.0f
                }
                count
            }
        }
    }
}
