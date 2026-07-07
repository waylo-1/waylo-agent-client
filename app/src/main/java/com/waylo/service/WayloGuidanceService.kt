package com.waylo.service

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import android.util.Log
import androidx.core.app.NotificationCompat
import com.waylo.R
import com.waylo.correction.CorrectionFlow
import com.waylo.guidance.GuidanceEngine
import com.waylo.overlay.OverlayManager
import com.waylo.ui.MainActivity
import com.waylo.voice.Speaker

/**
 * Foreground service that owns the overlay dot and the TTS Speaker, so both
 * persist across every app and the home screen — independent of any Activity
 * lifecycle.
 *
 * The service runs as a normal foreground service while only showing the dot.
 * It elevates to the mediaProjection foreground type lazily, only when a screen
 * capture is actually needed (see [ScreenCaptureManager]). This avoids the
 * Android 14+ requirement that a mediaProjection FGS must have an active
 * projection at startForeground time.
 */
class WayloGuidanceService : Service() {

    companion object {
        private const val TAG = "Waylo"
        const val CHANNEL_ID = "waylo_guidance"
        const val NOTIFICATION_ID = 42

        const val ACTION_START_GUIDANCE = "com.waylo.action.START_GUIDANCE"
        const val ACTION_STOP_GUIDANCE = "com.waylo.action.STOP_GUIDANCE"

        @Volatile
        var instance: WayloGuidanceService? = null
            private set

        fun start(context: Context) {
            val intent = Intent(context, WayloGuidanceService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, WayloGuidanceService::class.java))
        }
    }

    /** Process-lived TTS engine. Accessed via WayloGuidanceService.instance?.speaker. */
    lateinit var speaker: Speaker
        private set

    private var currentTask: String = ""

    override fun onCreate() {
        super.onCreate()
        instance = this
        Log.e("WAYLO_DOT", "Service onCreate fired")
        Log.e("WAYLO_DOT", "Overlay permission: ${Settings.canDrawOverlays(this)}")
        speaker = Speaker(this)
        OverlayManager.init(this) // service context — overlay survives leaving the app
        Log.e("WAYLO_DOT", "OverlayManager initialized")
        // The dot is shown ONLY when GuidanceEngine.start() runs — never on service start.
        // The correction-flow mic button is the fallback path into CorrectionFlow
        // (primary path is the volume-down double-press) and stays up for the
        // service's whole lifetime, not just during an active guidance run.
        OverlayManager.showMicButton { CorrectionFlow.start() }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startAsForeground()
        Log.d(TAG, "WayloGuidanceService started in foreground.")
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /**
     * Fired when the user swipes Waylo away from the recents screen. Stop
     * guidance, remove the dot, and shut the service down so nothing lingers.
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        GuidanceEngine.stop()
        OverlayManager.hideDot()
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        GuidanceEngine.stop()
        speaker.shutdown()
        OverlayManager.hideDot()
        OverlayManager.destroy()
        instance = null
        Log.d(TAG, "WayloGuidanceService destroyed.")
        super.onDestroy()
    }

    private fun startAsForeground() {
        // The manifest declares BOTH "specialUse" and "mediaProjection" for this
        // service. If startForeground() is called without an explicit type,
        // Android 14+ applies ALL manifest-declared types — including
        // mediaProjection, which requires an active MediaProjection grant that
        // doesn't exist yet at plain service start, and throws SecurityException.
        // Passing FOREGROUND_SERVICE_TYPE_SPECIAL_USE explicitly restricts this
        // initial call to just that type; mediaProjection is added later, only
        // once a capture actually begins, via enableMediaProjectionType().
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                buildNotification(),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            )
        } else {
            startForeground(NOTIFICATION_ID, buildNotification())
        }
    }

    private fun buildNotification(): Notification {
        val openApp = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val contentIntent = PendingIntent.getActivity(this, 0, openApp, flags)

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_dot)
            .setContentTitle(getString(R.string.notif_title))
            .setContentText(getString(R.string.notif_text))
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    /**
     * Elevate this foreground service to include the mediaProjection type.
     * Called by ScreenCaptureManager immediately before starting a projection.
     */
    fun enableMediaProjectionType() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            try {
                startForeground(
                    NOTIFICATION_ID,
                    buildNotification(),
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
                )
                Log.d(TAG, "Elevated FGS to mediaProjection type.")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to elevate FGS to mediaProjection type.", e)
            }
        }
    }

    // --- Guidance lifecycle ---

    /** Begin a guidance session for [task] with [steps]. */
    fun startGuidance(task: String, steps: List<com.waylo.ai.Step>) {
        currentTask = task
        GuidanceEngine.start(task, steps)
    }

    /** End the current guidance session (keeps the service alive for the dot). */
    fun stopGuidance() {
        GuidanceEngine.stop()
        OverlayManager.hideDot()
    }
}
