package com.fluttergaplessloop

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.graphics.BitmapFactory
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.util.Log

/**
 * Manages the Android [MediaSession] and media notification for a [LoopAudioPlayer].
 *
 * Responsibilities:
 * - Creates and maintains a [MediaSession] for lock-screen / notification controls.
 * - Builds a [Notification] with [Notification.MediaStyle] and posts it so the
 *   [AudioPlaybackService] foreground notification shows rich media metadata.
 * - Forwards [MediaSession.Callback] events back to Dart via [onRemoteCommand].
 *
 * ## Lifecycle
 * 1. Created once per plugin instance in [FlutterGaplessLoopPlugin.onAttachedToEngine].
 * 2. [setInfo] called when the Dart layer calls `setNowPlayingInfo`.
 * 3. [updatePlaybackState] called on every play/pause state change.
 * 4. [clear] called when the Dart layer calls `clearNowPlayingInfo`.
 * 5. [release] called in [FlutterGaplessLoopPlugin.onDetachedFromEngine].
 */
internal class NowPlayingManager(private val context: Context) {

    companion object {
        private const val TAG           = "NowPlayingManager"
        const val  NOTIFICATION_ID      = 7331
        const val  CHANNEL_ID           = "fgl_playback"
    }

    /**
     * Called when the user triggers a remote command (lock screen, headphone button).
     * Arguments: (command, seekPositionOrNull).
     * Commands: "play", "pause", "stop", "nextTrack", "previousTrack", "seek".
     */
    var onRemoteCommand: ((String, Double?) -> Unit)? = null

    private var mediaSession: MediaSession? = null
    private val notifManager =
        context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    // Cached info for notification rebuilds on playback state change
    private var cachedTitle:    String?    = null
    private var cachedArtist:   String?    = null
    private var cachedAlbum:    String?    = null
    private var cachedDuration: Double?    = null
    private var cachedArtwork:  ByteArray? = null

    init {
        createNotificationChannel()
    }

    // ── Public API ─────────────────────────────────────────────────────────────

    /**
     * Updates [MediaSession] metadata and rebuilds the notification.
     * Call when the Dart layer calls `setNowPlayingInfo`.
     */
    fun setInfo(
        title:        String?,
        artist:       String?,
        album:        String?,
        duration:     Double?,
        artworkBytes: ByteArray?
    ) {
        cachedTitle    = title
        cachedArtist   = artist
        cachedAlbum    = album
        cachedDuration = duration
        cachedArtwork  = artworkBytes

        val session = getOrCreateSession()

        val meta = MediaMetadata.Builder()
        title?.let    { meta.putString(MediaMetadata.METADATA_KEY_TITLE,  it) }
        artist?.let   { meta.putString(MediaMetadata.METADATA_KEY_ARTIST, it) }
        album?.let    { meta.putString(MediaMetadata.METADATA_KEY_ALBUM,  it) }
        duration?.let { meta.putLong(MediaMetadata.METADATA_KEY_DURATION, (it * 1000).toLong()) }
        artworkBytes?.let { bytes ->
            try {
                val bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                if (bmp != null) meta.putBitmap(MediaMetadata.METADATA_KEY_ART, bmp)
            } catch (e: Exception) {
                Log.w(TAG, "Failed to decode artwork: ${e.message}")
            }
        }
        session.setMetadata(meta.build())

        postNotification(session)
        Log.i(TAG, "setInfo: title=$title artist=$artist")
    }

    /**
     * Clears the [MediaSession] metadata and cancels the notification.
     * Call when the Dart layer calls `clearNowPlayingInfo`.
     */
    fun clear() {
        cachedTitle    = null
        cachedArtist   = null
        cachedAlbum    = null
        cachedDuration = null
        cachedArtwork  = null
        mediaSession?.isActive = false
        notifManager.cancel(NOTIFICATION_ID)
        Log.i(TAG, "Cleared")
    }

    /**
     * Updates the [PlaybackState] on the [MediaSession] and rebuilds the notification
     * to reflect the current play/pause state.
     *
     * @param isPlaying Current playback state.
     * @param positionMs Current position in milliseconds.
     * @param rate Playback speed multiplier.
     */
    fun updatePlaybackState(isPlaying: Boolean, positionMs: Long = 0L, rate: Float = 1f) {
        val session = mediaSession ?: return
        val stateCode = if (isPlaying) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED
        val pb = PlaybackState.Builder()
            .setState(stateCode, positionMs, rate)
            .setActions(
                PlaybackState.ACTION_PLAY            or
                PlaybackState.ACTION_PAUSE           or
                PlaybackState.ACTION_PLAY_PAUSE      or
                PlaybackState.ACTION_STOP            or
                PlaybackState.ACTION_SKIP_TO_NEXT    or
                PlaybackState.ACTION_SKIP_TO_PREVIOUS or
                PlaybackState.ACTION_SEEK_TO
            )
            .build()
        session.setPlaybackState(pb)
        // Rebuild notification only if metadata has been set
        if (cachedTitle != null || cachedArtist != null) {
            postNotification(session)
        }
        Log.d(TAG, "updatePlaybackState: isPlaying=$isPlaying pos=$positionMs")
    }

    /**
     * Builds a notification for use with [AudioPlaybackService.startForeground].
     *
     * Called by [AudioPlaybackService] as soon as `onStartCommand` fires so it can
     * call `startForeground` before the 5-second ANR window expires. The same
     * notification ID is used, so subsequent [postNotification] calls update the
     * foreground notification in-place.
     */
    fun buildStartupNotification(): Notification = buildNotification(getOrCreateSession())

    /** Releases the [MediaSession]. Call in [FlutterGaplessLoopPlugin.onDetachedFromEngine]. */
    fun release() {
        mediaSession?.release()
        mediaSession = null
        Log.i(TAG, "Released")
    }

    // ── Private ───────────────────────────────────────────────────────────────

    private fun getOrCreateSession(): MediaSession {
        return mediaSession ?: run {
            val session = MediaSession(context, "FlutterGaplessLoop")
            session.setCallback(object : MediaSession.Callback() {
                override fun onPlay()            { onRemoteCommand?.invoke("play",          null) }
                override fun onPause()           { onRemoteCommand?.invoke("pause",         null) }
                override fun onStop()            { onRemoteCommand?.invoke("stop",          null) }
                override fun onSkipToNext()      { onRemoteCommand?.invoke("nextTrack",     null) }
                override fun onSkipToPrevious()  { onRemoteCommand?.invoke("previousTrack", null) }
                override fun onSeekTo(pos: Long) { onRemoteCommand?.invoke("seek", pos / 1000.0) }
            })
            session.isActive = true
            mediaSession = session
            session
        }
    }

    private fun postNotification(session: MediaSession) {
        notifManager.notify(NOTIFICATION_ID, buildNotification(session))
    }

    @Suppress("DEPRECATION")
    private fun buildNotification(session: MediaSession): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, CHANNEL_ID)
        } else {
            Notification.Builder(context)
        }

        builder
            .setContentTitle(cachedTitle ?: "Playing")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setStyle(
                Notification.MediaStyle()
                    .setMediaSession(session.sessionToken)
            )

        cachedArtist?.let { builder.setContentText(it) }
        cachedArtwork?.let { bytes ->
            try {
                val bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                if (bmp != null) builder.setLargeIcon(bmp)
            } catch (_: Exception) {}
        }

        return builder.build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Audio Playback",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                setShowBadge(false)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
            notifManager.createNotificationChannel(channel)
        }
    }
}
