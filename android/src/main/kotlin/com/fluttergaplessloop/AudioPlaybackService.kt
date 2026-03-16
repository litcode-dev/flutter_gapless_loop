package com.fluttergaplessloop

import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * Foreground service that keeps audio playback alive when the screen is off.
 *
 * Android 8+ kills background processes that do not hold a foreground service
 * with a visible notification. This service satisfies that requirement.
 *
 * The service is started and stopped by [FlutterGaplessLoopPlugin] in response
 * to play/stop state changes. The notification content is provided by
 * [NowPlayingManager], which is updated independently via `setNowPlayingInfo`.
 *
 * ## Design notes
 * - A static [nowPlayingManager] reference allows the service to obtain the
 *   startup notification from [NowPlayingManager.buildStartupNotification]
 *   without binding or IPC. Both run in the same process.
 * - `START_NOT_STICKY` — if the OS kills the service, audio has already stopped,
 *   so there is no value in restarting automatically.
 */
internal class AudioPlaybackService : Service() {

    companion object {
        private const val TAG           = "AudioPlaybackService"
        private const val ACTION_START  = "com.fluttergaplessloop.ACTION_START"
        private const val ACTION_STOP   = "com.fluttergaplessloop.ACTION_STOP"

        /**
         * Static reference set by [FlutterGaplessLoopPlugin] so the service can
         * build its startup notification without binding.
         * Access is safe because both objects live in the same JVM process.
         */
        @Volatile var nowPlayingManager: NowPlayingManager? = null

        /** Starts the foreground service. Safe to call multiple times. */
        fun start(context: Context) {
            val intent = Intent(context, AudioPlaybackService::class.java).apply {
                action = ACTION_START
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
            Log.i(TAG, "start() requested")
        }

        /** Stops the foreground service and removes the notification. */
        fun stop(context: Context) {
            val intent = Intent(context, AudioPlaybackService::class.java).apply {
                action = ACTION_STOP
            }
            context.startService(intent)
            Log.i(TAG, "stop() requested")
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                // Must call startForeground within 5 s of startForegroundService.
                val notif = nowPlayingManager?.buildStartupNotification()
                    ?: buildFallbackNotification()
                startForeground(NowPlayingManager.NOTIFICATION_ID, notif)
                Log.i(TAG, "Foreground service started (notificationId=${NowPlayingManager.NOTIFICATION_ID})")
            }
            ACTION_STOP -> {
                @Suppress("DEPRECATION")
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                } else {
                    stopForeground(true)
                }
                stopSelf()
                Log.i(TAG, "Foreground service stopped")
            }
        }
        return START_NOT_STICKY
    }

    /**
     * Builds a minimal notification used only if [NowPlayingManager] is not yet
     * available (should not happen in normal operation, but guards against races).
     */
    @Suppress("DEPRECATION")
    private fun buildFallbackNotification(): android.app.Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            android.app.Notification.Builder(this, NowPlayingManager.CHANNEL_ID)
        } else {
            android.app.Notification.Builder(this)
        }
        return builder
            .setContentTitle("Playing audio")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setOngoing(true)
            .build()
    }
}
