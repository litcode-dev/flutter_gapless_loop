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

class AudioSessionManager(internal val context: Context) {

    companion object {
        private const val TAG = "AudioSessionManager"

        private val lock = Any()
        private val activeManagers = mutableListOf<AudioSessionManager>()
        private var sharedFocusRequest: AudioFocusRequest? = null

        private val sharedFocusListener = AudioManager.OnAudioFocusChangeListener { change ->
            val snapshot = synchronized(lock) { activeManagers.toList() }
            snapshot.forEach { it.handleFocusChange(change) }
        }

        internal fun requestShared(manager: AudioSessionManager): Boolean {
            synchronized(lock) {
                val alreadyHeld = activeManagers.isNotEmpty()
                activeManagers.add(manager)
                if (alreadyHeld) return true   // another engine already holds focus

                val am = manager.context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                        .setAudioAttributes(manager.audioAttributes)
                        .setAcceptsDelayedFocusGain(false)
                        .setOnAudioFocusChangeListener(sharedFocusListener)
                        .build()
                    sharedFocusRequest = req
                    am.requestAudioFocus(req) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
                } else {
                    @Suppress("DEPRECATION")
                    am.requestAudioFocus(
                        sharedFocusListener,
                        AudioManager.STREAM_MUSIC,
                        AudioManager.AUDIOFOCUS_GAIN
                    ) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
                }
            }
        }

        internal fun abandonShared(manager: AudioSessionManager) {
            synchronized(lock) {
                activeManagers.remove(manager)
                if (activeManagers.isNotEmpty()) return   // other engines still active

                val am = manager.context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    sharedFocusRequest?.let { am.abandonAudioFocusRequest(it) }
                    sharedFocusRequest = null
                } else {
                    @Suppress("DEPRECATION")
                    am.abandonAudioFocus(sharedFocusListener)
                }
            }
        }
    }

    var onFocusLoss: (() -> Unit)? = null
    var onFocusLossTransient: (() -> Unit)? = null
    var onFocusGain: (() -> Unit)? = null
    var onDuckVolume: ((Float) -> Unit)? = null
    var onRouteChange: ((String) -> Unit)? = null

    val audioAttributes: AudioAttributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
        .build()

    private var noisyReceiver: BroadcastReceiver? = null
    private var wasPlayingBeforeTransientLoss = false

    fun initialize() {
        registerNoisyReceiver()
    }

    fun requestAudioFocus(): Boolean = requestShared(this)

    fun abandonAudioFocus() = abandonShared(this)

    fun dispose() {
        abandonAudioFocus()
        unregisterNoisyReceiver()
        onFocusLoss          = null
        onFocusLossTransient = null
        onFocusGain          = null
        onDuckVolume         = null
        onRouteChange        = null
    }

    internal fun handleFocusChange(change: Int) {
        when (change) {
            AudioManager.AUDIOFOCUS_LOSS -> onFocusLoss?.invoke()
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                wasPlayingBeforeTransientLoss = true
                onFocusLossTransient?.invoke()
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> onDuckVolume?.invoke(0.2f)
            AudioManager.AUDIOFOCUS_GAIN -> {
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
                    onRouteChange?.invoke("headphonesUnplugged")
                }
            }
        }
        context.registerReceiver(receiver, IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY))
        noisyReceiver = receiver
    }

    private fun unregisterNoisyReceiver() {
        noisyReceiver?.let {
            try { context.unregisterReceiver(it) }
            catch (_: IllegalArgumentException) {}
            noisyReceiver = null
        }
    }
}
