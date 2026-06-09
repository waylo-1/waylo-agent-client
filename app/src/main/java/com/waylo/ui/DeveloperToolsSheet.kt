package com.waylo.ui

import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.Toast
import androidx.lifecycle.lifecycleScope
import com.google.android.material.bottomsheet.BottomSheetDialogFragment
import com.waylo.R
import com.waylo.accessibility.ElementFinder
import com.waylo.databinding.SheetDeveloperToolsBinding
import com.waylo.guidance.DemoTasks
import com.waylo.guidance.GuidanceEngine
import com.waylo.ocr.ScreenAnalysisPipeline
import com.waylo.overlay.OverlayManager
import com.waylo.permissions.PermissionManager
import com.waylo.screenshot.ScreenCaptureManager
import com.waylo.service.WayloGuidanceService
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Hidden developer menu (opened by tapping the logo 5 times). Hosts every
 * test control so the production UI stays clean.
 *
 * This sheet does NOT own the overlay or the Speaker — those live in
 * WayloGuidanceService. It only triggers actions on those singletons.
 */
class DeveloperToolsSheet : BottomSheetDialogFragment() {

    private var _binding: SheetDeveloperToolsBinding? = null
    private val binding get() = _binding!!

    override fun getTheme(): Int = R.style.Theme_Waylo_BottomSheet

    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?
    ): View {
        _binding = SheetDeveloperToolsBinding.inflate(inflater, container, false)
        return binding.root
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)

        // Screen capture permission
        binding.btnGrantCapture.setOnClickListener {
            ScreenCaptureManager.requestPermission(requireActivity())
        }

        // Overlay (owned by the service)
        binding.btnShowDot.setOnClickListener {
            if (!ensureOverlay()) return@setOnClickListener
            val m = resources.displayMetrics
            OverlayManager.showDot(m.widthPixels / 2, m.heightPixels / 2, getString(R.string.dot_tap_here))
        }
        binding.btnHideDot.setOnClickListener { OverlayManager.hideDot() }
        binding.btnRemoveDot.setOnClickListener { OverlayManager.hideDot() }

        // TTS — routed through the service-owned Speaker
        binding.btnNamaste.setOnClickListener {
            if (!Speaker_isAvailable()) {
                Toast.makeText(requireContext(), R.string.tts_unavailable, Toast.LENGTH_LONG).show()
                return@setOnClickListener
            }
            WayloGuidanceService.instance?.speaker?.speak("Hello, I am Waylo")
                ?: Toast.makeText(requireContext(), "Service not running", Toast.LENGTH_SHORT).show()
        }

        // Accessibility find
        binding.btnSearch.setOnClickListener {
            val query = binding.editElement.text.toString().trim()
            if (query.isNotEmpty()) runFind(query)
        }

        // OCR pipeline test
        binding.btnOcrFind.setOnClickListener {
            val description = binding.editOcr.text.toString().trim()
            if (description.isEmpty()) return@setOnClickListener
            if (!ensureOverlay()) return@setOnClickListener
            if (!ScreenCaptureManager.hasPermission()) {
                ScreenCaptureManager.requestPermission(requireActivity())
                Toast.makeText(requireContext(), R.string.dev_grant_capture, Toast.LENGTH_SHORT).show()
                return@setOnClickListener
            }
            runOcrPipeline(description)
        }

        // Emulator presets
        binding.btnFindSearch.setOnClickListener { launchTargetThenFind("search", null) }
        binding.btnFindSettings.setOnClickListener { launchTargetThenFind("settings", "com.android.settings") }
        binding.btnFindChrome.setOnClickListener { launchTargetThenFind("address", "com.android.chrome") }
        binding.btnFindCompose.setOnClickListener { launchTargetThenFind("compose", null) }

        // Demo tasks — full guidance loop
        binding.btnDemoPhoto.setOnClickListener { startDemo("Take a Photo", DemoTasks.takeAPhoto) }
        binding.btnDemoWhatsApp.setOnClickListener { startDemo("Open WhatsApp", DemoTasks.openWhatsApp) }
        binding.btnDemoYouTube.setOnClickListener { startDemo("Open YouTube", DemoTasks.openYouTube) }
        binding.btnStopGuidance.setOnClickListener { GuidanceEngine.stop() }
    }

    private fun Speaker_isAvailable(): Boolean =
        com.waylo.voice.Speaker.isTtsAvailable(requireContext())

    private fun startDemo(task: String, steps: List<com.waylo.ai.Step>) {
        if (!ensureOverlay()) return
        if (WayloGuidanceService.instance == null) {
            WayloGuidanceService.start(requireContext())
        }
        GuidanceEngine.start(task, steps)
        dismiss()
        // Drop to the home screen so the dot can find the app icon.
        val home = android.content.Intent(android.content.Intent.ACTION_MAIN).apply {
            addCategory(android.content.Intent.CATEGORY_HOME)
            flags = android.content.Intent.FLAG_ACTIVITY_NEW_TASK
        }
        startActivity(home)
    }

    private fun ensureOverlay(): Boolean {
        if (PermissionManager.hasOverlayPermission(requireContext())) return true
        PermissionManager.openOverlaySettings(requireContext())
        return false
    }

    private fun runFind(query: String) {
        if (!ensureOverlay()) return
        val match = ElementFinder.findElement(query)
        if (match != null) {
            val bounds = ElementFinder.getBoundsOnScreen(match.node)
            OverlayManager.showDot(bounds.centerX(), bounds.centerY(), getString(R.string.dot_tap_here))
            val label = match.node.text?.toString()
                ?: match.node.contentDescription?.toString() ?: "(no text)"
            Toast.makeText(requireContext(), "Found: $label (score: ${match.score})", Toast.LENGTH_LONG).show()
        } else {
            Toast.makeText(requireContext(), "Not found. Check logcat for candidates.", Toast.LENGTH_SHORT).show()
        }
    }

    private fun runOcrPipeline(description: String) {
        lifecycleScope.launch {
            val result = ScreenAnalysisPipeline.findAndShow(requireContext().applicationContext, description)
            if (result.source != "failed") {
                Toast.makeText(
                    requireContext(),
                    "Found via ${result.source}: ${result.label} at (${result.x},${result.y})",
                    Toast.LENGTH_LONG
                ).show()
            } else {
                Toast.makeText(requireContext(), "Pipeline failed — check logcat", Toast.LENGTH_SHORT).show()
            }
        }
    }

    private fun launchTargetThenFind(query: String, packageName: String?) {
        if (!ensureOverlay()) return
        binding.editElement.setText(query)
        if (packageName != null) {
            val intent = requireContext().packageManager.getLaunchIntentForPackage(packageName)
            if (intent != null) {
                intent.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
                try {
                    startActivity(intent)
                } catch (e: Exception) {
                    Toast.makeText(requireContext(), "Could not open $packageName", Toast.LENGTH_SHORT).show()
                }
            } else {
                Toast.makeText(requireContext(), "Could not open $packageName", Toast.LENGTH_SHORT).show()
            }
        }
        lifecycleScope.launch {
            delay(1500)
            runFind(query)
        }
    }

    override fun onDestroyView() {
        super.onDestroyView()
        _binding = null
    }
}
