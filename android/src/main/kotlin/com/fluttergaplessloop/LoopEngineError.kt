package com.fluttergaplessloop

/**
 * Sealed class representing all possible errors that the [LoopAudioEngine] can produce.
 *
 * Each subclass carries the data relevant to that specific failure mode.
 * Use [toMessage] to obtain a human-readable string suitable for passing to Dart via the
 * Flutter method channel.
 */
sealed class LoopEngineError {
    /** The file at [path] could not be located on disk. */
    data class FileNotFound(val path: String) : LoopEngineError()

    /** MediaCodec or MediaExtractor reported a decode failure described by [reason]. */
    data class DecodeFailed(val reason: String) : LoopEngineError()

    /** The file's MIME type [mimeType] is not supported by the engine. */
    data class UnsupportedFormat(val mimeType: String) : LoopEngineError()

    /** The loop region defined by [start] and [end] (in seconds) is not valid. */
    data class InvalidLoopRegion(val start: Double, val end: Double) : LoopEngineError()

    /** A seek to [requested] seconds was attempted but the track duration is only [duration] seconds. */
    data class SeekOutOfBounds(val requested: Double, val duration: Double) : LoopEngineError()

    /** The requested crossfade duration [requested] seconds exceeds the allowed [maximum] seconds. */
    data class CrossfadeTooLong(val requested: Double, val maximum: Double) : LoopEngineError()

    /** AudioTrack reported an error with the platform error code [errorCode]. */
    data class AudioTrackError(val errorCode: Int) : LoopEngineError()

    /** The Android audio focus request was denied for [reason]. */
    data class AudioFocusDenied(val reason: String) : LoopEngineError()

    /** Human-readable description suitable for sending to Dart. */
    fun toMessage(): String = when (this) {
        is FileNotFound      -> "File not found: $path"
        is DecodeFailed      -> "Decode failed: $reason"
        is UnsupportedFormat -> "Unsupported audio format: $mimeType"
        is InvalidLoopRegion -> "Invalid loop region: start=$start end=$end"
        is SeekOutOfBounds   -> "Seek $requested s out of bounds (duration: $duration s)"
        is CrossfadeTooLong  -> "Crossfade $requested s exceeds maximum $maximum s"
        is AudioTrackError   -> "AudioTrack error code: $errorCode"
        is AudioFocusDenied  -> "Audio focus denied: $reason"
    }
}

/**
 * A [RuntimeException] that wraps a [LoopEngineError], allowing engine errors to be thrown
 * and caught through standard Kotlin exception-handling mechanisms.
 *
 * The exception [message] is derived from [LoopEngineError.toMessage], so it is always
 * human-readable and safe to forward to Dart.
 *
 * @property error The underlying [LoopEngineError] that caused this exception.
 */
class LoopAudioException(val error: LoopEngineError) : RuntimeException(error.toMessage())

/**
 * Sealed class representing the discrete operational states of the audio engine.
 *
 * State transitions flow generally as:
 * [Idle] -> [Loading] -> [Ready] -> [Playing] <-> [Paused] -> [Stopped] -> [Idle]
 *
 * Any state can transition to [Error] if the engine encounters a [LoopEngineError].
 *
 * [rawValue] provides the canonical lowercase string identifier used when serialising
 * the state for the Flutter event channel.
 */
sealed class EngineState {
    /** The engine has no audio loaded and is dormant. */
    object Idle : EngineState()

    /** Audio is being decoded and buffered; the engine is not yet ready to play. */
    object Loading : EngineState()

    /** Audio is fully loaded and the engine is ready to begin playback. */
    object Ready : EngineState()

    /** Audio is actively playing. */
    object Playing : EngineState()

    /** Playback is paused at the current position. */
    object Paused : EngineState()

    /** Playback has been stopped and the position has been reset. */
    object Stopped : EngineState()

    /** The engine has encountered an unrecoverable [error] and must be reloaded. */
    data class Error(val error: LoopEngineError) : EngineState()

    /** Canonical lowercase string identifier for this state, used by the Flutter event channel. */
    val rawValue: String get() = when (this) {
        is Idle    -> "idle"
        is Loading -> "loading"
        is Ready   -> "ready"
        is Playing -> "playing"
        is Paused  -> "paused"
        is Stopped -> "stopped"
        is Error   -> "error"
    }
}
