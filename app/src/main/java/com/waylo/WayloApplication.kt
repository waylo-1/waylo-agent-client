package com.waylo

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import com.waylo.service.WayloGuidanceService

/**
 * Application subclass. Creates the notification channel used by the foreground
 * guidance service on app startup.
 */
class WayloApplication : Application() {

    override fun onCreate() {
        super.onCreate()
        createGuidanceNotificationChannel()
    }

    private fun createGuidanceNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                WayloGuidanceService.CHANNEL_ID,
                getString(R.string.notif_channel_name),
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = getString(R.string.notif_text)
                setShowBadge(false)
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }
}
