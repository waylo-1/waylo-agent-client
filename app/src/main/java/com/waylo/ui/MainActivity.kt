package com.waylo.ui

import android.content.Intent
import android.os.Bundle
import android.os.SystemClock
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import androidx.recyclerview.widget.LinearLayoutManager
import com.waylo.R
import com.waylo.ai.GeminiClient
import com.waylo.databinding.ActivityMainBinding
import com.waylo.guidance.GuidanceEngine
import com.waylo.overlay.OverlayManager
import com.waylo.permissions.PermissionManager
import com.waylo.screenshot.ScreenCaptureManager
import com.waylo.service.WayloGuidanceService
import kotlinx.coroutines.launch

/**
 * Production home screen. Clean navy UI with a task card, recent list, and an
 * active-status footer. All developer/test controls are hidden behind a 5-tap
 * easter egg on the logo.
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

        OverlayManager.init(applicationContext)

        binding.logo.setOnClickListener { onLogoTapped() }

        binding.statusCluster.setOnClickListener {
            PermissionsSheet().show(supportFragmentManager, "permissions")
        }

        binding.btnStartGuidance.setOnClickListener {
            val task = binding.editTask.text.toString().trim()
            if (task.isEmpty()) {
                Toast.makeText(this, R.string.main_task_hint, Toast.LENGTH_SHORT).show()
            } else {
                startGuidanceFor(task)
            }
        }

        setupRecentList()
    }

    /**
     * Calls the Waylo backend for a plan, shows a loading state, then hands the
     * steps to [GuidanceEngine]. The foreground service keeps guidance alive once
     * the user switches to the target app (e.g. Instagram).
     */
    private fun startGuidanceFor(task: String) {
        // Keep guidance alive across app switches.
        WayloGuidanceService.start(this)

        // Loading state.
        binding.btnStartGuidance.isEnabled = false
        binding.btnStartGuidance.setText(R.string.thinking)
        Toast.makeText(this, R.string.thinking, Toast.LENGTH_SHORT).show()

        lifecycleScope.launch {
            try {
                val steps = GeminiClient.requestPlan(task)
                if (steps.isEmpty()) {
                    Toast.makeText(
                        this@MainActivity,
                        R.string.element_not_found,
                        Toast.LENGTH_LONG
                    ).show()
                    WayloGuidanceService.stop(this@MainActivity)
                } else {
                    GuidanceEngine.instance.startGuidance(applicationContext, steps)
                    // Drop to the home screen so the user can open the target app
                    // and follow the dot.
                    moveTaskToBack(true)
                }
            } catch (e: Exception) {
                Toast.makeText(
                    this@MainActivity,
                    getString(R.string.guidance_failed),
                    Toast.LENGTH_LONG
                ).show()
                WayloGuidanceService.stop(this@MainActivity)
            } finally {
                binding.btnStartGuidance.isEnabled = true
                binding.btnStartGuidance.setText(R.string.main_start_guidance)
                refreshActiveStatus()
            }
        }
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
