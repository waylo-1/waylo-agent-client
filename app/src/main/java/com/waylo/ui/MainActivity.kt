package com.waylo.ui

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.recyclerview.widget.LinearLayoutManager
import com.waylo.R
import com.waylo.accessibility.WayloAccessibilityService
import com.waylo.databinding.ActivityMainBinding
import com.waylo.guidance.DemoTasks
import com.waylo.guidance.GuidanceEngine
import com.waylo.permissions.PermissionManager
import com.waylo.screenshot.ScreenCaptureManager
import com.waylo.service.WayloGuidanceService

/**
 * Production home screen. The overlay dot and TTS are owned by
 * [WayloGuidanceService], NOT this Activity, so they persist after the user
 * leaves Waylo. This screen only starts the service and kicks off guidance.
 */
class MainActivity : AppCompatActivity() {

    private lateinit var binding: ActivityMainBinding

    // Easter egg: 5 taps on the logo opens developer tools.
    private var logoTapCount = 0
    private var lastTapTime = 0L

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        // NOTE: do NOT call OverlayManager.init() here — the overlay is owned by
        // WayloGuidanceService with the service context so it survives leaving
        // the app. Start the service so the dot + Speaker come alive.
        startGuidanceService()

        binding.logo.setOnClickListener { onLogoTapped() }

        binding.statusCluster.setOnClickListener {
            PermissionsSheet().show(supportFragmentManager, "permissions")
        }

        binding.btnStartGuidance.setOnClickListener {
            onStartGuidanceClicked()
        }

        setupRecentList()
    }

    override fun onResume() {
        super.onResume()
        refreshStatusCluster()
        refreshActiveStatus()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == ScreenCaptureManager.REQUEST_CODE &&
            resultCode == RESULT_OK && data != null
        ) {
            ScreenCaptureManager.onPermissionResult(resultCode, data)
            refreshStatusCluster()
        }
    }

    private fun startGuidanceService() {
        val serviceIntent = Intent(this, WayloGuidanceService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(serviceIntent)
        } else {
            startService(serviceIntent)
        }
    }

    private fun onStartGuidanceClicked() {
        val task = binding.editTask.text.toString().trim()
        if (task.isEmpty()) {
            Toast.makeText(this, R.string.main_task_hint, Toast.LENGTH_SHORT).show()
            return
        }

        // Overlay permission is mandatory for the dot to appear.
        if (!Settings.canDrawOverlays(this)) {
            Toast.makeText(
                this,
                "Please grant 'Draw over apps' permission first",
                Toast.LENGTH_LONG
            ).show()
            startActivity(
                Intent(
                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                    Uri.parse("package:$packageName")
                )
            )
            return
        }

        // Accessibility service is needed to read the screen.
        if (WayloAccessibilityService.instance == null) {
            Toast.makeText(
                this,
                "Please enable Waylo in Accessibility Settings first",
                Toast.LENGTH_LONG
            ).show()
            startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
            return
        }

        val steps = when {
            task.contains("photo", ignoreCase = true) ||
                task.contains("camera", ignoreCase = true) -> DemoTasks.takeAPhoto
            task.contains("whatsapp", ignoreCase = true) -> DemoTasks.openWhatsApp
            task.contains("youtube", ignoreCase = true) -> DemoTasks.openYouTube
            else -> {
                Toast.makeText(this, "Try: camera, whatsapp, or youtube", Toast.LENGTH_SHORT).show()
                return
            }
        }

        // Ensure the service is running, then start guidance.
        startGuidanceService()
        GuidanceEngine.start(task, steps)

        // Small delay before minimizing so the engine can initialize.
        Handler(Looper.getMainLooper()).postDelayed({
            val home = Intent(Intent.ACTION_MAIN).apply { addCategory(Intent.CATEGORY_HOME) }
            home.flags = Intent.FLAG_ACTIVITY_NEW_TASK
            startActivity(home)
        }, 500)
    }

    private fun setupRecentList() {
        val placeholders = listOf("Instagram Reel", "PhonePe Transfer", "YouTube search")
        binding.recentList.layoutManager = LinearLayoutManager(this)
        binding.recentList.adapter = RecentTasksAdapter(placeholders)
        binding.recentList.isNestedScrollingEnabled = false
    }

    private fun refreshStatusCluster() {
        binding.dotOverlay.setBackgroundResource(
            badge(PermissionManager.hasOverlayPermission(this))
        )
        binding.dotAccessibility.setBackgroundResource(
            badge(PermissionManager.hasAccessibilityEnabled(this))
        )
        binding.dotCapture.setBackgroundResource(
            badge(PermissionManager.hasScreenCapturePermission())
        )
    }

    private fun refreshActiveStatus() {
        val active = WayloGuidanceService.instance != null
        if (active) {
            binding.activeDot.setBackgroundResource(R.drawable.badge_green)
            binding.activeText.setText(R.string.main_active)
        } else {
            binding.activeDot.setBackgroundResource(R.drawable.badge_gray)
            binding.activeText.setText(R.string.main_inactive)
        }
    }

    private fun badge(granted: Boolean): Int =
        if (granted) R.drawable.badge_green else R.drawable.badge_red

    private fun onLogoTapped() {
        val now = SystemClock.elapsedRealtime()
        // Reset the counter if taps are more than 600ms apart.
        if (now - lastTapTime > 600) logoTapCount = 0
        lastTapTime = now
        logoTapCount++
        if (logoTapCount >= 5) {
            logoTapCount = 0
            DeveloperToolsSheet().show(supportFragmentManager, "dev_tools")
        }
    }
}
