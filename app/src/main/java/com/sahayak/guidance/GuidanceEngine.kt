// TODO: Day 10 — implement the main orchestrator that runs a plan step by step.
// Receives a List<Step>, drives the dot + voice through each one, and advances
// when the user taps. Singleton accessed via GuidanceEngine.instance.
package com.sahayak.guidance

import com.sahayak.ai.Step

/**
 * Main orchestrator. Walks the user through a generated plan one step at a time,
 * coordinating ElementFinder, OverlayManager, Speaker and the fallback chain.
 *
 * Singleton — accessed via [GuidanceEngine.instance].
 */
class GuidanceEngine private constructor() {

    companion object {
        val instance: GuidanceEngine by lazy { GuidanceEngine() }
    }

    private var steps: List<Step> = emptyList()
    private var currentIndex: Int = 0

    /** TODO: Day 10 — load a plan and begin the happy-path guidance loop. */
    fun startGuidance(steps: List<Step>) {
        this.steps = steps
        this.currentIndex = 0
        // TODO: execute first step.
    }

    /** TODO: Day 10 — advance to the next step after the user taps. */
    fun nextStep() {
        // TODO
    }

    /** TODO: Day 10 — stop the session and clean up the overlay. */
    fun stop() {
        // TODO
    }
}
