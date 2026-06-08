package com.waylo.service

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import com.waylo.R
import com.waylo.ui.MainActivity

/**
 * Foreground service that hosts the guidance session. Android requires screen
 * capture (MediaProjection) to run inside a foreground service of type
 * mediaProjection on API 29+.
 *
 * Singleton-style access via [instance] while running.
 */
class WayloGuidanceService : Service() {

    companion object {
        private const val TAG = "Waylo"
        const val CHANNEL_ID = "waylo_guidance"
        const val NOTIFICATION_ID = 42

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

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startAsForeground()
        Log.d(TAG, "WayloGuidanceService started in foreground.")
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        instance = null
        Log.d(TAG, "WayloGuidanceService destroyed.")
        super.onDestroy()
    }

    private fun startAsForeground() {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
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

    // --- Guidance lifecycle (stubs; GuidanceEngine wires these in Week 2) ---

    /** TODO: Week 2 — begin a guidance session driven by GuidanceEngine. */
    fun startGuidance() {
        Log.d(TAG, "startGuidance() called (stub).")
    }

    /** TODO: Week 2 — end the current guidance session and stop the service. */
    fun stopGuidance() {
        Log.d(TAG, "stopGuidance() called (stub).")
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }
}
