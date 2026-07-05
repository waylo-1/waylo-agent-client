package com.waylo.ui.onboarding

import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import androidx.fragment.app.Fragment
import com.waylo.R
import com.waylo.databinding.FragmentObPermissionBinding
import com.waylo.permissions.PermissionManager
import com.waylo.screenshot.ScreenCaptureManager

/**
 * Reusable onboarding screen for a single permission. The [type] argument
 * selects which permission's copy, icon, and grant action are shown.
 */
class PermissionFragment : Fragment() {

    enum class PermType { OVERLAY, ACCESSIBILITY, CAPTURE }

    private var _binding: FragmentObPermissionBinding? = null
    private val binding get() = _binding!!

    private lateinit var type: PermType

    companion object {
        private const val ARG_TYPE = "type"

        fun newInstance(type: PermType): PermissionFragment =
            PermissionFragment().apply {
                arguments = Bundle().apply { putString(ARG_TYPE, type.name) }
            }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        type = PermType.valueOf(arguments?.getString(ARG_TYPE) ?: PermType.OVERLAY.name)
    }

    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?
    ): View {
        _binding = FragmentObPermissionBinding.inflate(inflater, container, false)
        return binding.root
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)
        bindContent()

        binding.btnAction.setOnClickListener {
            when (type) {
                PermType.OVERLAY -> PermissionManager.openOverlaySettings(requireContext())
                PermType.ACCESSIBILITY -> PermissionManager.openAccessibilitySettings(requireContext())
                PermType.CAPTURE -> ScreenCaptureManager.requestPermission(requireActivity())
            }
        }

        binding.btnSkip.setOnClickListener {
            (activity as? OnboardingHost)?.finishOnboarding()
        }
    }

    private fun bindContent() {
        when (type) {
            PermType.OVERLAY -> {
                binding.icon.setImageResource(R.drawable.ic_dot)
                binding.title.setText(R.string.ob_overlay_title)
                binding.body.setText(R.string.ob_overlay_body)
                binding.btnAction.setText(R.string.ob_overlay_button)
                binding.btnSkip.visibility = View.GONE
            }
            PermType.ACCESSIBILITY -> {
                binding.icon.setImageResource(R.drawable.ic_eye)
                binding.title.setText(R.string.ob_accessibility_title)
                binding.body.setText(R.string.ob_accessibility_body)
                binding.btnAction.setText(R.string.ob_accessibility_button)
                binding.btnSkip.visibility = View.GONE
            }
            PermType.CAPTURE -> {
                binding.icon.setImageResource(R.drawable.ic_phone)
                binding.title.setText(R.string.ob_capture_title)
                binding.body.setText(R.string.ob_capture_body)
                binding.btnAction.setText(R.string.ob_capture_button)
                binding.btnSkip.visibility = View.VISIBLE
            }
        }
    }

    override fun onResume() {
        super.onResume()
        refreshStatus()
    }

    /** Called by the host when this page becomes visible. */
    fun refreshStatus() {
        if (_binding == null) return
        val granted = isGranted()
        if (granted) {
            binding.statusDot.setBackgroundResource(R.drawable.badge_green)
            binding.statusText.setText(R.string.status_granted)
            when (type) {
                PermType.CAPTURE -> {
                    // Last screen: turn the action button into "All Done".
                    binding.btnAction.setText(R.string.ob_finish)
                    binding.btnAction.setOnClickListener {
                        (activity as? OnboardingHost)?.finishOnboarding()
                    }
                    binding.btnSkip.visibility = View.GONE
                }
                else -> {
                    // Bug fix: the button used to keep saying "Grant Permission"
                    // (and keep re-opening the settings screen if tapped) for the
                    // whole auto-advance delay below. Flip it to "Next" and make
                    // it actually advance immediately so there's no stale/wrong
                    // action visible even for that brief window.
                    binding.btnAction.setText(R.string.ob_next)
                    binding.btnAction.setOnClickListener {
                        (activity as? OnboardingHost)?.goToNext()
                    }
                    // Auto-advance after a short beat once granted, so most users
                    // never even need to tap "Next".
                    binding.statusText.postDelayed({
                        (activity as? OnboardingHost)?.goToNext()
                    }, 1000)
                }
            }
        } else {
            binding.statusDot.setBackgroundResource(R.drawable.badge_red)
            binding.statusText.setText(R.string.status_not_granted)
        }
    }

    private fun isGranted(): Boolean = when (type) {
        PermType.OVERLAY -> PermissionManager.hasOverlayPermission(requireContext())
        PermType.ACCESSIBILITY -> PermissionManager.hasAccessibilityEnabled(requireContext())
        PermType.CAPTURE -> PermissionManager.hasScreenCapturePermission()
    }

    override fun onDestroyView() {
        super.onDestroyView()
        _binding = null
    }
}
