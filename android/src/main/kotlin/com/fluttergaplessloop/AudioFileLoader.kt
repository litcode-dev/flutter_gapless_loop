package com.fluttergaplessloop

import android.content.res.AssetFileDescriptor
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.util.Log
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

    /** Codec dequeue timeout in microseconds (10 ms). */
    private const val CODEC_TIMEOUT_US = 10_000L

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
     * Core decode loop shared by [decode] and [decodeAsset].
     *
     * Feeds encoded data from [extractor] through MediaCodec input buffers and
     * collects decoded PCM from output buffers until END_OF_STREAM is signalled.
     *
     * Codec state machine:
     *   configure() → start() → [dequeueInputBuffer / queueInputBuffer loop] →
     *   [dequeueOutputBuffer loop] → EOS → stop() → release()
     *
     * @throws LoopAudioException on any codec failure.
     */
    private fun decodeFromExtractor(
        extractor: MediaExtractor,
        onProgress: ((Float) -> Unit)?
    ): DecodedAudio {
        val trackIndex = findAudioTrack(extractor)
            ?: throw LoopAudioException(
                LoopEngineError.UnsupportedFormat("No audio track found in file")
            )
        extractor.selectTrack(trackIndex)

        val format      = extractor.getTrackFormat(trackIndex)
        val mime        = format.getString(MediaFormat.KEY_MIME)
            ?: throw LoopAudioException(LoopEngineError.UnsupportedFormat("null MIME type"))
        val sampleRate  = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        val channelCount = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)

        val durationUs = if (format.containsKey(MediaFormat.KEY_DURATION))
            format.getLong(MediaFormat.KEY_DURATION) else 0L
        val estFrames = ((durationUs / 1_000_000.0) * sampleRate).toInt().coerceAtLeast(1)

        Log.i(TAG, "Decoding: mime=$mime rate=$sampleRate ch=$channelCount ~$estFrames frames")

        val codec = MediaCodec.createDecoderByType(mime)
        try {
            codec.configure(format, null, null, 0)
            codec.start()

            val chunks       = ArrayList<FloatArray>(estFrames / 2048 + 1)
            var totalSamples = 0
            val bufInfo      = MediaCodec.BufferInfo()
            var inputDone    = false
            var outputDone   = false
            var outputFormat = codec.outputFormat

            while (!outputDone) {
                // ── Feed compressed data into the codec ───────────────────────
                if (!inputDone) {
                    val inIdx = codec.dequeueInputBuffer(CODEC_TIMEOUT_US)
                    if (inIdx >= 0) {
                        val inBuf = codec.getInputBuffer(inIdx)
                            ?: throw LoopAudioException(
                                LoopEngineError.DecodeFailed("Null input buffer at $inIdx")
                            )
                        val sampleSize = extractor.readSampleData(inBuf, 0)
                        if (sampleSize < 0) {
                            codec.queueInputBuffer(
                                inIdx, 0, 0, 0L,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM
                            )
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(
                                inIdx, 0, sampleSize, extractor.sampleTime, 0
                            )
                            extractor.advance()
                        }
                    }
                }

                // ── Collect decoded PCM from output ───────────────────────────
                val outIdx = codec.dequeueOutputBuffer(bufInfo, CODEC_TIMEOUT_US)
                when {
                    outIdx >= 0 -> {
                        val outBuf = codec.getOutputBuffer(outIdx)
                        if (outBuf != null && bufInfo.size > 0) {
                            val chunk = extractFloatChunk(outBuf, bufInfo, outputFormat)
                            chunks.add(chunk)
                            totalSamples += chunk.size
                            if (durationUs > 0 && onProgress != null) {
                                onProgress(
                                    (totalSamples / channelCount).toFloat() / estFrames.toFloat()
                                )
                            }
                        }
                        codec.releaseOutputBuffer(outIdx, false)
                        if (bufInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                            outputDone = true
                        }
                    }
                    outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        outputFormat = codec.outputFormat
                        Log.d(TAG, "Output format changed: $outputFormat")
                    }
                    // INFO_TRY_AGAIN_LATER: loop again
                }
            }

            // Concatenate all chunks into one contiguous FloatArray
            val pcm = FloatArray(totalSamples)
            var offset = 0
            for (chunk in chunks) {
                chunk.copyInto(pcm, offset)
                offset += chunk.size
            }

            val totalFrames = totalSamples / channelCount
            Log.i(TAG, "Decode complete: $totalFrames frames, ${sampleRate}Hz, ${channelCount}ch")
            return DecodedAudio(pcm, sampleRate, channelCount, totalFrames)

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
     * Extracts samples from [outBuf] and normalizes to Float [-1.0, 1.0].
     *
     * Handles PCM_16BIT (most common) and PCM_FLOAT codec output.
     * Encoding is detected from [format]'s KEY_PCM_ENCODING, defaulting to PCM_16BIT.
     */
    private fun extractFloatChunk(
        outBuf: ByteBuffer,
        bufInfo: MediaCodec.BufferInfo,
        format: MediaFormat
    ): FloatArray {
        outBuf.position(bufInfo.offset)
        outBuf.limit(bufInfo.offset + bufInfo.size)

        val encoding = if (format.containsKey(MediaFormat.KEY_PCM_ENCODING))
            format.getInteger(MediaFormat.KEY_PCM_ENCODING)
        else
            AudioFormat.ENCODING_PCM_16BIT

        return when (encoding) {
            AudioFormat.ENCODING_PCM_FLOAT -> {
                val buf = outBuf.order(ByteOrder.nativeOrder()).asFloatBuffer()
                FloatArray(buf.remaining()).also { arr -> buf.get(arr) }
            }
            else -> {
                // PCM_16BIT: normalize by dividing by 32768 to get [-1.0, 1.0]
                val buf = outBuf.order(ByteOrder.nativeOrder()).asShortBuffer()
                FloatArray(buf.remaining()) { buf.get() / 32768.0f }
            }
        }
    }
}
