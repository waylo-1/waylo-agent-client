package com.sahayak.ui

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import android.util.DisplayMetrics
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import com.sahayak.R
import com.sahayak.accessibility.ElementFinder
import com.sahayak.databinding.ActivityMainBinding
import com.sahayak.overlay.OverlayManager
import com.sahayak.voice.Speaker

/**
 * Home screen with the Week-1 test harness:
 *  - Day 4: show/hide the red dot overlay at screen center.
 *  - Day 5: type an element description, find it on screen, place the dot on it.
 *  - Day 6: speak the Hindi welcome line via TTS.
 */
class MainActivity : AppCompatActivity() {

    private lateinit var binding: ActivityMainBinding
    private lateinit var speaker: Speaker

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        OverlayManager.init(applicationContext)
        speaker = Speaker(applicationContext)

        // --- Day 4: overlay test buttons ---
        binding.btnShowDot.setOnClickListener {
            if (!hasOverlayPermission()) {
                requestOverlayPermission()
                return@setOnClickListener
            }
            val metrics = screenSize()
            OverlayManager.showDot(
                metrics.widthPixels / 2,
                metrics.heightPixels / 2,
                getString(R.string.dot_tap_here)
            )
        }

        binding.btnHideDot.setOnClickListener {
            OverlayManager.hideDot()
        }

        // --- Day 6: TTS test ---
        binding.btnNamaste.setOnClickListener {
            speaker.speak(getString(R.string.tts_welcome))
        }

        // --- Day 5: connect accessibility + overlay ---
        binding.btnSearch.setOnClickListener {
            if (!hasOverlayPermission()) {
                requestOverlayPermission()
                return@setOnClickListener
            }
            val query = binding.editElement.text.toString().trim()
            if (query.isEmpty()) return@setOnClickListener

            val match = ElementFinder.findElement(query)
            if (match != null) {
                val bounds = ElementFinder.getBoundsOnScreen(match.node)
                OverlayManager.showDot(
                    bounds.centerX(),
                    bounds.centerY(),
                    getString(R.string.dot_tap_here)
                )
            } else {
                Toast.makeText(
                    this,
                    getString(R.string.toast_element_not_found),
                    Toast.LENGTH_SHORT
                ).show()
            }
        }

        binding.btnRemoveDot.setOnClickListener {
            OverlayManager.hideDot()
        }
    }

    override fun onDestroy() {
        speaker.shutdown()
        super.onDestroy()
    }

    private fun hasOverlayPermission(): Boolean = Settings.canDrawOverlays(this)

    private fun requestOverlayPermission() {
        val intent = Intent(
            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
            Uri.parse("package:$packageName")
        )
        startActivity(intent)
        Toast.makeText(this, R.string.element_not_found, Toast.LENGTH_SHORT).show()
    }

    @Suppress("DEPRECATION")
    private fun screenSize(): DisplayMetrics {
        val metrics = DisplayMetrics()
        windowManager.defaultDisplay.getMetrics(metrics)
        return metrics
    }
}
