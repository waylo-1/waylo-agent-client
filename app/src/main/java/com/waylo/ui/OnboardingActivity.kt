package com.waylo.ui

import android.content.Intent
import android.os.Bundle
import android.view.View
import android.widget.LinearLayout
import androidx.appcompat.app.AppCompatActivity
import androidx.viewpager2.adapter.FragmentStateAdapter
import androidx.viewpager2.widget.ViewPager2
import com.waylo.R
import com.waylo.databinding.ActivityOnboardingBinding
import com.waylo.permissions.PermissionManager
import com.waylo.screenshot.ScreenCaptureManager
import com.waylo.ui.onboarding.OnboardingHost
import com.waylo.ui.onboarding.PermissionFragment
import com.waylo.ui.onboarding.WelcomeFragment

/**
 * Four-screen ViewPager2 onboarding: welcome, then one screen per permission.
 * If everything is already set up, it skips straight to [MainActivity].
 */
class OnboardingActivity : AppCompatActivity(), OnboardingHost {

    private lateinit var binding: ActivityOnboardingBinding
    private lateinit var pagerAdapter: OnboardingPagerAdapter

    private val pageCount = 4

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        if (PermissionManager.isFullySetup(this)) {
            goToMain()
            return
        }

        binding = ActivityOnboardingBinding.inflate(layoutInflater)
        setContentView(binding.root)

        pagerAdapter = OnboardingPagerAdapter(this)
        binding.pager.adapter = pagerAdapter

        // Disable back-swipe on the welcome screen (screen 1).
        binding.pager.registerOnPageChangeCallback(object : ViewPager2.OnPageChangeCallback() {
            override fun onPageSelected(position: Int) {
                updateProgressDots(position)
                // Refresh the visible permission fragment's status badge.
                (pagerAdapter.fragmentAt(position) as? PermissionFragment)?.refreshStatus()
            }
        })

        buildProgressDots()
        updateProgressDots(0)
    }

    override fun onResume() {
        super.onResume()
        // Re-check the currently visible permission page when returning from Settings.
        val current = binding.pager.currentItem
        (pagerAdapter.fragmentAt(current) as? PermissionFragment)?.refreshStatus()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == ScreenCaptureManager.REQUEST_CODE &&
            resultCode == RESULT_OK && data != null
        ) {
            ScreenCaptureManager.onPermissionResult(resultCode, data)
            val current = binding.pager.currentItem
            (pagerAdapter.fragmentAt(current) as? PermissionFragment)?.refreshStatus()
        }
    }

    // --- OnboardingHost ---

    override fun goToNext() {
        val next = binding.pager.currentItem + 1
        if (next < pageCount) {
            binding.pager.setCurrentItem(next, true)
        } else {
            finishOnboarding()
        }
    }

    override fun finishOnboarding() {
        goToMain()
    }

    private fun goToMain() {
        startActivity(Intent(this, MainActivity::class.java))
        finish()
    }

    // --- Progress dots ---

    private fun buildProgressDots() {
        binding.progressDots.removeAllViews()
        val size = resources.displayMetrics.density * 10
        val margin = resources.displayMetrics.density * 6
        for (i in 0 until pageCount) {
            val dot = View(this)
            val params = LinearLayout.LayoutParams(size.toInt(), size.toInt())
            params.marginStart = margin.toInt()
            params.marginEnd = margin.toInt()
            dot.layoutParams = params
            dot.setBackgroundResource(R.drawable.dot_progress_inactive)
            binding.progressDots.addView(dot)
        }
    }

    private fun updateProgressDots(active: Int) {
        for (i in 0 until binding.progressDots.childCount) {
            binding.progressDots.getChildAt(i).setBackgroundResource(
                if (i == active) R.drawable.dot_progress_active
                else R.drawable.dot_progress_inactive
            )
        }
    }

    /** Adapter for the four onboarding pages. */
    private class OnboardingPagerAdapter(
        private val activity: AppCompatActivity
    ) : FragmentStateAdapter(activity) {

        override fun getItemCount(): Int = 4

        override fun createFragment(position: Int) = when (position) {
            0 -> WelcomeFragment()
            1 -> PermissionFragment.newInstance(PermissionFragment.PermType.OVERLAY)
            2 -> PermissionFragment.newInstance(PermissionFragment.PermType.ACCESSIBILITY)
            else -> PermissionFragment.newInstance(PermissionFragment.PermType.CAPTURE)
        }

        /** Look up the currently instantiated fragment for [position], if any. */
        fun fragmentAt(position: Int): androidx.fragment.app.Fragment? =
            activity.supportFragmentManager.findFragmentByTag("f$position")
    }
}
