package com.waylo.ui.onboarding

/**
 * Contract the onboarding fragments use to drive page navigation in their host
 * activity, decoupling them from the concrete Activity.
 */
interface OnboardingHost {
    fun goToNext()
    fun finishOnboarding()
}
