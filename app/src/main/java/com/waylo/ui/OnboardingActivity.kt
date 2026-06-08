package com.waylo.ui

import android.content.Intent
import android.os.Bundle
import android.provider.Settings
import androidx.appcompat.app.AppCompatActivity
import com.waylo.accessibility.WayloAccessibilityService
import com.waylo.databinding.ActivityOnboardingBinding

/**
 * First screen the user sees. Walks them through enabling the accessibility
 * service. Once the service is connected, jumps straight to [MainActivity].
 */
class OnboardingActivity : AppCompatActivity() {

    private lateinit var binding: ActivityOnboardingBinding

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // If the service is already enabled, skip onboarding entirely.
        if (WayloAccessibilityService.instance != null) {
            goToMain()
            return
        }

        binding = ActivityOnboardingBinding.inflate(layoutInflater)
        setContentView(binding.root)

        binding.btnEnable.setOnClickListener {
            startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
        }
    }

    override fun onResume() {
        super.onResume()
        // Returning from Settings — check whether the service is now connected.
        if (WayloAccessibilityService.instance != null) {
            goToMain()
        }
    }

    private fun goToMain() {
        startActivity(Intent(this, MainActivity::class.java))
        finish()
    }
}
