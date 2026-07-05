package com.waylo.ui

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.view.View
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.recyclerview.widget.LinearLayoutManager
import com.waylo.R
import com.waylo.accessibility.WayloAccessibilityService
import com.waylo.data.RecentTasksStore
import com.waylo.databinding.ActivityMainBinding
import com.waylo.guidance.GuidanceEngine
import com.waylo.permissions.PermissionManager
import com.waylo.screenshot.ScreenCaptureManager
import com.waylo.service.WayloGuidanceService

/**
 * Production home screen. The overlay dot and TTS are owned by
 * [WayloGuidanceService], NOT this Activity, so they persist after the user
 * leaves Waylo. This screen takes the user's task, asks the Waylo backend for a
 * plan, and kicks off guidance.
 */
class MainActivity : AppCompatActivity() {

    private lateinit var binding: ActivityMainBinding

    // Easter egg: 5 taps on the logo opens developer tools.
    private var logoTapCount = 0
    private var lastTapTime = 0L

    // Task waiting to start once screen-capture permission is granted.
    private var pendingTask: String? = null

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
        setupQuickTasks()
    }

    override fun onResume() {
        super.onResume()
        refreshStatusCluster()
        refreshActiveStatus()
        refreshRecentList()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == ScreenCaptureManager.REQUEST_CODE) {
            if (resultCode == RESULT_OK && data != null) {
                ScreenCaptureManager.onPermissionResult(resultCode, data)
                refreshStatusCluster()
                // If a task was waiting on this permission, launch it now.
                pendingTask?.let { task ->
                    pendingTask = null
                    launchGuidance(task)
                }
            } else {
                // User declined screen capture. Continue without OCR/vision —
                // Layer 1 (accessibility) still works.
                Toast.makeText(
                    this,
                    "Screen access denied — guidance will work but may be less accurate.",
                    Toast.LENGTH_LONG
                ).show()
                pendingTask?.let { task ->
                    pendingTask = null
                    launchGuidance(task)
                }
            }
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

    /**
     * Validate permissions, then hand the task to [GuidanceEngine], which calls
     * the Waylo backend for a plan and runs guidance. The foreground service
     * keeps guidance alive once the user switches to the target app.
     */
    private fun onStartGuidanceClicked() {
        val task = binding.editTask.text.toString().trim()
        if (task.isEmpty()) {
            Toast.makeText(this, "Please describe what you want to do", Toast.LENGTH_SHORT).show()
            return
        }

        // Overlay permission is mandatory for the dot to appear.
        if (!Settings.canDrawOverlays(this)) {
            Toast.makeText(
                this,
                "Please grant Draw Over Apps permission first",
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

        // Ensure the service is running so the dot + Speaker are alive.
        startGuidanceService()

        // Screen capture powers the OCR + vision fallback layers. If it isn't
        // granted yet, request it FIRST and defer starting guidance until the
        // grant arrives in onActivityResult — otherwise the capture dialog gets
        // dismissed when we minimize to home and OCR/vision can never run.
        if (!ScreenCaptureManager.hasPermission()) {
            pendingTask = task
            Toast.makeText(this, "Allow screen access to continue", Toast.LENGTH_SHORT).show()
            ScreenCaptureManager.requestPermission(this)
            return
        }

        launchGuidance(task)
    }

    /**
     * Actually start guidance and minimize to home. Called either directly (if
     * capture permission is already granted) or from onActivityResult once the
     * user responds to the capture dialog.
     */
    private fun launchGuidance(task: String) {
        startGuidanceService()
        Toast.makeText(this, "Starting guidance for: $task", Toast.LENGTH_SHORT).show()
        RecentTasksStore.addRecent(this, task)
        GuidanceEngine.start(task) // calls backend, gets real steps

        // Minimize to home so the user can open the target app and follow the
        // dot. Small delay lets the engine initialize.
        Handler(Looper.getMainLooper()).postDelayed({
            startActivity(
                Intent(Intent.ACTION_MAIN).apply {
                    addCategory(Intent.CATEGORY_HOME)
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK
                }
            )
        }, 800)
        refreshActiveStatus()
    }

    private fun setupRecentList() {
        binding.recentList.layoutManager = LinearLayoutManager(this)
        binding.recentList.isNestedScrollingEnabled = false
        refreshRecentList()
    }

    /**
     * Re-reads persisted recents and rebinds the list — call after a task is
     * run. Shows the recent list once there is at least one real recent task;
     * otherwise shows the curated quick-task cards instead (first launch).
     */
    private fun refreshRecentList() {
        val recents = RecentTasksStore.getRecents(this)
        binding.recentList.adapter = RecentTasksAdapter(recents) { task ->
            binding.editTask.setText(task)
            onStartGuidanceClicked()
        }

        val hasRecents = recents.isNotEmpty()
        binding.recentHeader.visibility = if (hasRecents) View.VISIBLE else View.GONE
        binding.recentList.visibility = if (hasRecents) View.VISIBLE else View.GONE
        binding.quickTasksSection.visibility = if (hasRecents) View.GONE else View.VISIBLE
    }

    /** Wire the four curated quick-task cards — tapping one starts guidance the same way typing does. */
    private fun setupQuickTasks() {
        val tasks = mapOf(
            binding.quickTask1 to getString(R.string.quick_task_whatsapp_photo),
            binding.quickTask2 to getString(R.string.quick_task_video_call),
            binding.quickTask3 to getString(R.string.quick_task_youtube_search),
            binding.quickTask4 to getString(R.string.quick_task_text_size)
        )
        tasks.forEach { (card, task) ->
            card.setOnClickListener {
                binding.editTask.setText(task)
                onStartGuidanceClicked()
            }
        }
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
