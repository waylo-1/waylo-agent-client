package com.waylo.permissions

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.waylo.accessibility.WayloAccessibilityService
import com.waylo.screenshot.ScreenCaptureManager

/**
 * Single entry point for all of Waylo's permission checks and requests.
 *
 * Waylo relies on four permissions:
 *  1. Overlay (SYSTEM_ALERT_WINDOW) — to draw the dot.
 *  2. Accessibility service — to read the screen.
 *  3. Screen capture (MediaProjection) — for the OCR fallback.
 *  4. Microphone (RECORD_AUDIO) — for voice input (post-MVP feature).
 */
object PermissionManager {

    const val REQUEST_MICROPHONE = 2001

    // --- Checks ---

    fun hasOverlayPermission(context: Context): Boolean =
        Settings.canDrawOverlays(context)

    fun hasAccessibilityEnabled(context: Context): Boolean {
        // The most reliable signal is our own connected service instance.
        if (WayloAccessibilityService.instance != null) return true

        // Fall back to the secure setting list (covers the case where the
        // service is enabled but our process was just started).
        val enabled = Settings.Secure.getString(
            context.contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
        ) ?: return false
        val expected = "${context.packageName}/${WayloAccessibilityService::class.java.name}"
        return enabled.split(':').any { it.equals(expected, ignoreCase = true) }
    }

    fun hasScreenCapturePermission(): Boolean =
        ScreenCaptureManager.hasPermission()

    fun hasMicrophonePermission(context: Context): Boolean =
        ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.RECORD_AUDIO
        ) == PackageManager.PERMISSION_GRANTED

    // --- Open settings (non-runtime permissions) ---

    fun openOverlaySettings(context: Context) {
        val intent = Intent(
            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
            Uri.parse("package:${context.packageName}")
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
    }

    fun openAccessibilitySettings(context: Context) {
        val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
    }

    // --- Request runtime permissions ---

    fun requestMicrophonePermission(activity: Activity) {
        ActivityCompat.requestPermissions(
            activity,
            arrayOf(Manifest.permission.RECORD_AUDIO),
            REQUEST_MICROPHONE
        )
    }

    // --- Overall readiness ---

    /** True only when all four permissions are granted. */
    fun isFullySetup(context: Context): Boolean =
        hasOverlayPermission(context) &&
            hasAccessibilityEnabled(context) &&
            hasScreenCapturePermission() &&
            hasMicrophonePermission(context)
}
