package com.waylo.ui.onboarding

import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import androidx.fragment.app.Fragment
import com.waylo.databinding.FragmentObWelcomeBinding

/**
 * Onboarding screen 1: welcome + "Get Started".
 */
class WelcomeFragment : Fragment() {

    private var _binding: FragmentObWelcomeBinding? = null
    private val binding get() = _binding!!

    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?
    ): View {
        _binding = FragmentObWelcomeBinding.inflate(inflater, container, false)
        return binding.root
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)
        binding.btnGetStarted.setOnClickListener {
            (activity as? OnboardingHost)?.goToNext()
        }
    }

    override fun onDestroyView() {
        super.onDestroyView()
        _binding = null
    }
}
