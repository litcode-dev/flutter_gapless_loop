package com.fluttergaplessloop

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.util.Log

/**
 * Manages Android audio focus and audio route change notifications.
 *
 * Audio focus prevents multiple apps from playing audio simultaneously.
 * This manager requests [AudioManager.AUDIOFOCUS_GAIN] before playback and responds
 * to focus changes per Android audio best practices.
 *
 * Route changes (headphone unplug) are detected via [AudioManager.ACTION_AUDIO_BECOMING_NOISY].
 *
 * ## Lifecycle
 * 1. Call [initialize] once after construction to register receivers.
 * 2. Call [requestAudioFocus] before [android.media.AudioTrack.play].
 * 3. Call [abandonAudioFocus] on pause/stop.
 * 4. Call [dispose] when the engine is torn down.
 *
 * All callbacks fire on the Android main thread. Dispatch to coroutines as needed.
 */
class AudioSessionManager(private val context: Context) {

    companion object {
        private const val TAG = "AudioSessionManager"
    }

    // ─── Callbacks ─────────────────────────────────────────────────────────

    /** Called on permanent focus loss (another app starts playing). Stop playback. */
    var onFocusLoss: (() -> Unit)? = null

    /** Called on transient focus loss (phone call). Pause; resume on [onFocusGain]. */
    var onFocusLossTransient: (() -> Unit)? = null

    /** Called when focus is regained after a transient loss. Resume if was playing. */
    var onFocusGain: (() -> Unit)? = null

    /**
     * Called when the system requests volume ducking or restoration.
     * Argument: 0.2f = duck to 20%, 1.0f = restore full volume.
     */
    var onDuckVolume: ((Float) -> Unit)? = null

    /**
     * Called when the audio route changes requiring a pause.
     * Argument: "headphonesUnplugged" (matches iOS route change reason string).
     */
    var onRouteChange: ((String) -> Unit)? = null

    // ─── AudioAttributes ──────────────────────────────────────────────────

    /**
     * AudioAttributes for media music playback.
     * Pass to [android.media.AudioTrack.Builder.setAudioAttributes] so the system
     * applies correct routing, volume, and focus policies.
     */
    val audioAttributes: AudioAttributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
        .build()

    // ─── Private state ─────────────────────────────────────────────────────

    private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private var focusRequest: AudioFocusRequest? = null   // API 26+
    private var noisyReceiver: BroadcastReceiver? = null

    /** Set to true when we paused due to transient focus loss, so we auto-resume on GAIN. */
    private var wasPlayingBeforeTransientLoss = false

    // ─── Public API ────────────────────────────────────────────────────────

    /**
     * Registers the [AudioManager.ACTION_AUDIO_BECOMING_NOISY] broadcast receiver.
     * Must be called once before any playback begins.
     */
    fun initialize() {
        registerNoisyReceiver()
        Log.i(TAG, "Initialized")
    }

    /**
     * Requests [AudioManager.AUDIOFOCUS_GAIN] from the Android audio system.
     *
     * Uses [AudioFocusRequest] on API 26+, deprecated overload on API 24–25.
     *
     * @return true if focus was granted; false if denied.
     */
    fun requestAudioFocus(): Boolean {
        val granted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            requestFocusModern()
        } else {
            requestFocusLegacy()
        }
        Log.i(TAG, "requestAudioFocus: granted=$granted")
        return granted
    }

    /**
     * Abandons audio focus. Call on pause and stop so other apps can take focus.
     */
    fun abandonAudioFocus() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
        } else {
            @Suppress("DEPRECATION")
            audioManager.abandonAudioFocus(focusChangeListener)
        }
        Log.i(TAG, "Audio focus abandoned")
    }

    /**
     * Releases all resources. Must be called when [LoopAudioEngine.dispose] is called.
     * After dispose the instance must not be reused.
     */
    fun dispose() {
        abandonAudioFocus()
        unregisterNoisyReceiver()
        onFocusLoss          = null
        onFocusLossTransient = null
        onFocusGain          = null
        onDuckVolume         = null
        onRouteChange        = null
        Log.i(TAG, "Disposed")
    }

    // ─── Private ──────────────────────────────────────────────────────────

    /** API 26+ focus request path. */
    private fun requestFocusModern(): Boolean {
        val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
            .setAudioAttributes(audioAttributes)
            .setAcceptsDelayedFocusGain(false)
            .setOnAudioFocusChangeListener(focusChangeListener)
            .build()
        focusRequest = req
        return audioManager.requestAudioFocus(req) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    /** Legacy focus request for API 24–25. */
    @Suppress("DEPRECATION")
    private fun requestFocusLegacy(): Boolean {
        return audioManager.requestAudioFocus(
            focusChangeListener,
            AudioManager.STREAM_MUSIC,
            AudioManager.AUDIOFOCUS_GAIN
        ) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    /**
     * Reacts to audio focus changes. Always called on the Android main thread.
     */
    private val focusChangeListener = AudioManager.OnAudioFocusChangeListener { change ->
        Log.d(TAG, "Focus change: $change")
        when (change) {
            AudioManager.AUDIOFOCUS_LOSS -> {
                // Permanent loss: another app owns audio. Stop completely.
                onFocusLoss?.invoke()
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                // Temporary loss (phone call). Pause; will resume on GAIN.
                wasPlayingBeforeTransientLoss = true
                onFocusLossTransient?.invoke()
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                // Another app needs brief audio (navigation prompt). Duck to 20%.
                onDuckVolume?.invoke(0.2f)
            }
            AudioManager.AUDIOFOCUS_GAIN -> {
                // Focus restored. Un-duck; resume if we paused due to transient loss.
                onDuckVolume?.invoke(1.0f)
                if (wasPlayingBeforeTransientLoss) {
                    wasPlayingBeforeTransientLoss = false
                    onFocusGain?.invoke()
                }
            }
        }
    }

    private fun registerNoisyReceiver() {
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) {
                    Log.i(TAG, "BECOMING_NOISY — headphones unplugged")
                    onRouteChange?.invoke("headphonesUnplugged")
                }
            }
        }
        context.registerReceiver(receiver, IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY))
        noisyReceiver = receiver
        Log.d(TAG, "BECOMING_NOISY receiver registered")
    }

    private fun unregisterNoisyReceiver() {
        noisyReceiver?.let { receiver ->
            try {
                context.unregisterReceiver(receiver)
                Log.d(TAG, "BECOMING_NOISY receiver unregistered")
            } catch (e: IllegalArgumentException) {
                // Receiver was never registered (e.g. dispose before initialize)
                Log.w(TAG, "Receiver not registered: ${e.message}")
            }
            noisyReceiver = null
        }
    }
}
