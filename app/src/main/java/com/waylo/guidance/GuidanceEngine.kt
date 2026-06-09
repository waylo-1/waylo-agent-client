// Main orchestrator that runs a plan step by step.
// Receives a List<Step>, drives the dot + voice through each one, and advances
// when the user taps the highlighted element. Singleton via GuidanceEngine.instance.
package com.waylo.guidance

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.util.TypedValue
import com.waylo.accessibility.ElementFinder
import com.waylo.ai.Step
import com.waylo.overlay.OverlayManager
import com.waylo.service.WayloGuidanceService
import com.waylo.voice.Speaker

/**
 * Main orchestrator. Walks the user through a generated plan one step at a time,
 * coordinating [ElementFinder], [OverlayManager] and [Speaker].
 *
 * Flow per step: find the element → place the dot on it → speak the instruction →
 * wait for the user to tap → advance. On completion it speaks a friendly closer
 * and tears down the foreground service.
 *
 * Singleton — accessed via [GuidanceEngine.instance].
 */
class GuidanceEngine private constructor() {

    companion object {
        private const val TAG = "Waylo"

        /** Delay before resolving the next step, letting the new screen settle. */
        private const val STEP_SETTLE_MS = 900L

        /** Spoken when the whole plan is finished. */
        private const val COMPLETION_PHRASE = "Sab kuch ho gaya!"

        val instance: GuidanceEngine by lazy { GuidanceEngine() }
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    private var appContext: Context? = null
    private var speaker: Speaker? = null

    private var steps: List<Step> = emptyList()
    private var currentIndex: Int = 0

    @Volatile
    private var running: Boolean = false

    /** True once a step's dot is shown and we're waiting for the user to tap. */
    @Volatile
    private var awaitingTap: Boolean = false

    /** True while guidance is active (used by callers/UI). */
    fun isRunning(): Boolean = running

    /**
     * Load a plan and begin the guidance loop. Safe to call from any thread —
     * all UI work is posted to the main thread.
     */
    fun startGuidance(context: Context, steps: List<Step>) {
        if (steps.isEmpty()) {
            Log.w(TAG, "GuidanceEngine: startGuidance called with no steps.")
            return
        }

        mainHandler.post {
            this.appContext = context.applicationContext
            if (speaker == null) {
                speaker = Speaker(appContext!!)
            }
            this.steps = steps
            this.currentIndex = 0
            this.running = true
            Log.d(TAG, "GuidanceEngine: starting plan with ${steps.size} steps.")
            executeCurrentStep()
        }
    }

    /**
     * Called when the user taps something on screen (wired from the accessibility
     * service on TYPE_VIEW_CLICKED). Advances to the next step.
     */
    fun onUserTap() {
        if (!running || !awaitingTap) return
        awaitingTap = false
        Log.d(TAG, "GuidanceEngine: user tap detected, advancing from step ${currentIndex + 1}.")
        mainHandler.postDelayed({ nextStep() }, STEP_SETTLE_MS)
    }

    /** Advance to the next step, or finish if the plan is complete. */
    fun nextStep() {
        if (!running) return
        currentIndex++
        executeCurrentStep()
    }

    /** Stop the session and clean up the overlay + service. */
    fun stop() {
        mainHandler.post {
            Log.d(TAG, "GuidanceEngine: stopping.")
            running = false
            awaitingTap = false
            OverlayManager.hideDot()
            speaker?.stop()
            speaker?.shutdown()
            speaker = null
            appContext?.let { WayloGuidanceService.stop(it) }
            steps = emptyList()
            currentIndex = 0
        }
    }

    // --- internals ---

    private fun executeCurrentStep() {
        if (!running) return

        if (currentIndex >= steps.size) {
            finish()
            return
        }

        val step = steps[currentIndex]
        Log.d(TAG, "GuidanceEngine: step ${currentIndex + 1}/${steps.size} — '${step.instruction}' (find: '${step.findDescription}')")

        val match = ElementFinder.findElement(step.findDescription)
        if (match != null) {
            val bounds = ElementFinder.getBoundsOnScreen(match.node)
            // showDot positions the top-left of the dot view; offset so the dot's
            // centre lands on the element's centre.
            val half = dp(70f)
            val x = bounds.centerX() - half
            val y = bounds.centerY() - half
            OverlayManager.showDot(x, y, step.instruction)
        } else {
            // Element not located on the current screen. Keep any existing dot,
            // still speak the instruction so the user can act, then wait for a tap.
            Log.d(TAG, "GuidanceEngine: element not found for step ${currentIndex + 1}; speaking instruction anyway.")
        }

        speaker?.speak(step.instruction)
        awaitingTap = true
    }

    private fun finish() {
        Log.d(TAG, "GuidanceEngine: plan complete.")
        running = false
        awaitingTap = false
        OverlayManager.hideDot()
        speaker?.speak(COMPLETION_PHRASE)
        // Give the closer a moment to play before tearing down the service.
        mainHandler.postDelayed({
            appContext?.let { WayloGuidanceService.stop(it) }
        }, 2500L)
    }

    private fun dp(value: Float): Int {
        val ctx = appContext ?: return value.toInt()
        return TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP,
            value,
            ctx.resources.displayMetrics
        ).toInt()
    }
}
