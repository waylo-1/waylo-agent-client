package com.waylo

import android.app.Activity
import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import android.os.Bundle
import com.waylo.service.WayloGuidanceService

/**
 * Application subclass. Creates the notification channel used by the foreground
 * guidance service on app startup, and tracks activity lifecycle so guidance
 * cleanup can react to the app being fully closed.
 *
 * The primary dot-removal mechanism is [WayloGuidanceService.onTaskRemoved]
 * (fires when the user swipes Waylo from recents). This lifecycle tracking is a
 * backup only — it deliberately does NOT stop guidance when the user leaves to
 * another app, because that's the intended flow (follow the dot in the target app).
 */
class WayloApplication : Application() {

    override fun onCreate() {
        super.onCreate()
        createGuidanceNotificationChannel()
        registerLifecycleTracking()
    }

    private fun registerLifecycleTracking() {
        registerActivityLifecycleCallbacks(object : ActivityLifecycleCallbacks {
            private var activityCount = 0

            override fun onActivityStarted(activity: Activity) {
                activityCount++
            }

            override fun onActivityStopped(activity: Activity) {
                activityCount--
                // Don't stop guidance when leaving to another app — that's
                // intentional. Only the service's onTaskRemoved should stop the
                // dot when the user explicitly closes Waylo via swipe.
            }

            override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}
            override fun onActivityResumed(activity: Activity) {}
            override fun onActivityPaused(activity: Activity) {}
            override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
            override fun onActivityDestroyed(activity: Activity) {}
        })
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
