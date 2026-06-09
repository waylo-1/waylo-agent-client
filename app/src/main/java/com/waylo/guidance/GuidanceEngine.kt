package com.waylo.guidance

import android.content.Context
import android.graphics.Point
import android.util.Log
import android.view.WindowManager
import com.waylo.accessibility.ElementFinder
import com.waylo.ai.GeminiClient
import com.waylo.ai.Step
import com.waylo.ocr.ScreenAnalysisPipeline
import com.waylo.overlay.OverlayManager
import com.waylo.service.WayloGuidanceService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Main orchestrator. Walks the user through a plan one step at a time:
 * speaks each instruction, locates the target element, places the dot on it,
 * and advances when the user taps the dot.
 *
 * Owned by the process (not an Activity), so guidance survives the user leaving
 * the Waylo app. If the pipeline can't find a target, the dot is still shown at
 * a sensible fallback position so the user always sees feedback.
 */
object GuidanceEngine {

    private const val TAG = "WAYLO_DOT"

    /** Kept to honour the PRD contract (`GuidanceEngine.instance`). Self-reference. */
    var instance: GuidanceEngine? = this

    private var steps: List<Step> = emptyList()
    private var currentIndex = 0
    private var isRunning = false
    private var currentTask: String = ""

    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    private var activeJob: Job? = null

    /** Begin guidance for [task] using the supplied [stepList]. */
    fun start(task: String, stepList: List<Step>) {
        if (stepList.isEmpty()) {
            Log.e(TAG, "start() called with no steps.")
            return
        }
        currentTask = task
        steps = stepList
        currentIndex = 0
        isRunning = true
        Log.e(TAG, "Guidance started: '$task' with ${stepList.size} steps.")
        executeStep(0)
    }

    /**
     * Entry point for real backend calls. Fetches a plan from the backend via
     * [GeminiClient], then delegates to the [start] overload that takes a
     * concrete step list.
     */
    fun start(task: String) {
        if (isRunning) stop()
        isRunning = true
        currentTask = task
        currentIndex = 0
        Log.e(TAG, "GuidanceEngine.start: calling backend for task: $task")
        WayloGuidanceService.instance?.speaker?.speak("Got it. Finding the steps for you.")

        scope.launch {
            try {
                val steps = GeminiClient.getPlan(task) // calls backend /plan
                Log.e(TAG, "Backend returned ${steps.size} steps")
                if (steps.isEmpty()) {
                    withContext(Dispatchers.Main) {
                        WayloGuidanceService.instance?.speaker
                            ?.speak("Sorry, I couldn't understand that task. Please try again.")
                        isRunning = false
                    }
                    return@launch
                }
                withContext(Dispatchers.Main) {
                    start(task, steps) // delegate to the existing List<Step> overload
                }
            } catch (e: Exception) {
                Log.e(TAG, "Backend call failed: ${e.message}", e)
                withContext(Dispatchers.Main) {
                    WayloGuidanceService.instance?.speaker
                        ?.speak("Network error. Please check your internet and try again.")
                    isRunning = false
                }
            }
        }
    }

    /** Stop guidance, clear the dot, and silence the voice. */
    fun stop() {
        isRunning = false
        activeJob?.cancel()
        activeJob = null
        OverlayManager.hideDot()
        WayloGuidanceService.instance?.speaker?.stop()
        Log.e(TAG, "Guidance stopped.")
    }

    private fun executeStep(index: Int) {
        if (!isRunning || index >= steps.size) {
            if (index >= steps.size) taskComplete()
            return
        }

        currentIndex = index
        val step = steps[index]
        Log.e(TAG, "executeStep called for index $index: ${step.instruction}")
        Log.e(TAG, "findDescription: ${step.findDescription}")

        WayloGuidanceService.instance?.speaker?.speak(step.instruction)

        activeJob?.cancel()
        activeJob = scope.launch {
            val service = WayloGuidanceService.instance
            if (service == null) {
                Log.e(TAG, "No service context — cannot run guidance.")
                return@launch
            }

            // Try the pipeline, but never let it hang the loop.
            val result = withTimeoutOrNull(4000) {
                // Step 1 is almost always "find the app icon on the home screen".
                if (index == 0) {
                    val home = withContext(Dispatchers.IO) {
                        ElementFinder.findOnHomeScreen(step.findDescription)
                    }
                    if (home != null) {
                        val bounds = ElementFinder.getBoundsOnScreen(home.node)
                        return@withTimeoutOrNull ScreenAnalysisPipeline.PipelineResult(
                            x = bounds.centerX(),
                            y = bounds.centerY(),
                            source = "home-screen",
                            confidence = home.score.toFloat(),
                            label = step.findDescription
                        )
                    }
                }
                ScreenAnalysisPipeline.find(service, step.findDescription)
            }

            withContext(Dispatchers.Main) {
                if (result != null && result.source != "failed") {
                    Log.e(TAG, "Pipeline found: ${result.source} at ${result.x},${result.y}")
                    OverlayManager.showDotAtResult(result)
                } else {
                    // Fallback: place the dot at a visible position so the user
                    // always gets feedback, even if detection failed.
                    Log.e(TAG, "Pipeline failed/timed out, showing dot at fallback position")
                    val ctx: Context = service
                    val wm = ctx.getSystemService(Context.WINDOW_SERVICE) as WindowManager
                    val size = Point()
                    @Suppress("DEPRECATION")
                    wm.defaultDisplay.getSize(size)
                    OverlayManager.showDot(size.x / 2, size.y / 3, step.instruction)
                }
            }
        }
    }

    /** Called when the user taps the dot (or the target). Advance one step. */
    fun onUserTappedTarget() {
        if (!isRunning) return
        Log.e(TAG, "User tapped target on step ${currentIndex + 1}.")
        executeStep(currentIndex + 1)
    }

    private fun taskComplete() {
        OverlayManager.hideDot()
        WayloGuidanceService.instance?.speaker?.speak("All done! Task complete.")
        isRunning = false
        Log.e(TAG, "Task complete: '$currentTask'")
    }

    fun getCurrentStep(): Step? = steps.getOrNull(currentIndex)

    fun isActive(): Boolean = isRunning
}
