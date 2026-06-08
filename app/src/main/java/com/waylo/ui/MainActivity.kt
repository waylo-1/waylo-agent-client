package com.waylo.ui

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import android.util.DisplayMetrics
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import com.waylo.R
import com.waylo.accessibility.ElementFinder
import com.waylo.databinding.ActivityMainBinding
import com.waylo.overlay.OverlayManager
import com.waylo.voice.Speaker
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Home screen with the Week-1 test harness:
 *  - Day 4: show/hide the red dot overlay at screen center.
 *  - Day 5: type an element description, find it on screen, place the dot on it.
 *  - Day 6: speak the welcome line via TTS.
 *  - Fix 3: emulator test targets that open a real app, wait, then run findElement.
 */
class MainActivity : AppCompatActivity() {

    private lateinit var binding: ActivityMainBinding
    private lateinit var speaker: Speaker

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        OverlayManager.init(applicationContext)

        // Initialise TTS early so onInit has time to fire before the button is tapped.
        speaker = Speaker(this)

        // Warn the user up front if no TTS engine exists on this device.
        if (!Speaker.isTtsAvailable(this)) {
            Toast.makeText(this, R.string.tts_unavailable, Toast.LENGTH_LONG).show()
        }

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
            if (!Speaker.isTtsAvailable(this)) {
                Toast.makeText(this, R.string.tts_unavailable, Toast.LENGTH_LONG).show()
                return@setOnClickListener
            }
            speaker.speak(getString(R.string.tts_welcome))
        }

        // --- Day 5: connect accessibility + overlay ---
        binding.btnSearch.setOnClickListener {
            val query = binding.editElement.text.toString().trim()
            if (query.isNotEmpty()) runFind(query)
        }

        binding.btnRemoveDot.setOnClickListener {
            OverlayManager.hideDot()
        }

        // --- Fix 3: emulator test targets ---
        binding.btnFindSearch.setOnClickListener {
            launchTargetThenFind("search", null)
        }
        binding.btnFindSettings.setOnClickListener {
            launchTargetThenFind("settings", "com.android.settings")
        }
        binding.btnFindChrome.setOnClickListener {
            launchTargetThenFind("address", "com.android.chrome")
        }
        binding.btnFindCompose.setOnClickListener {
            launchTargetThenFind("compose", null)
        }
    }

    override fun onDestroy() {
        speaker.shutdown()
        super.onDestroy()
    }

    /**
     * Pre-fill the search field with [query], optionally launch the target app
     * package, wait for the accessibility tree to settle, then run the find.
     */
    private fun launchTargetThenFind(query: String, packageName: String?) {
        if (!hasOverlayPermission()) {
            requestOverlayPermission()
            return
        }
        binding.editElement.setText(query)

        if (packageName != null) {
            val launched = launchPackage(packageName)
            if (!launched) {
                Toast.makeText(this, "Could not open $packageName", Toast.LENGTH_SHORT).show()
            }
        }

        // Give the launched app's accessibility tree time to update before searching.
        lifecycleScope.launch {
            delay(1500)
            runFind(query)
        }
    }

    /** Run ElementFinder for [query]; show the dot + a result toast. */
    private fun runFind(query: String) {
        if (!hasOverlayPermission()) {
            requestOverlayPermission()
            return
        }
        val match = ElementFinder.findElement(query)
        if (match != null) {
            val bounds = ElementFinder.getBoundsOnScreen(match.node)
            OverlayManager.showDot(
                bounds.centerX(),
                bounds.centerY(),
                getString(R.string.dot_tap_here)
            )
            val label = match.node.text?.toString()
                ?: match.node.contentDescription?.toString()
                ?: "(no text)"
            Toast.makeText(
                this,
                "Found: $label (score: ${match.score})",
                Toast.LENGTH_LONG
            ).show()
        } else {
            Toast.makeText(
                this,
                "Not found. Check logcat for candidates.",
                Toast.LENGTH_SHORT
            ).show()
        }
    }

    /** Try to launch an app by package name. Returns false if not installed. */
    private fun launchPackage(packageName: String): Boolean {
        val intent = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(Intent.ACTION_MAIN).setPackage(packageName)
                .addCategory(Intent.CATEGORY_LAUNCHER)
        return try {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
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
