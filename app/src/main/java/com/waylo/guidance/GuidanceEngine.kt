package com.waylo.guidance

import android.content.Context
import android.graphics.Point
import android.util.Log
import android.view.WindowManager
import com.waylo.accessibility.ElementFinder
import com.waylo.ai.GeminiClient
import com.waylo.ai.PlanParser
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
import java.util.UUID

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

    private var steps: List<StepMetadata> = emptyList()
    private var currentIndex = 0
    private var isRunning = false
    private var currentTask: String = ""

    /** Target app package from the plan's appPackage field; biases L0 matching. */
    private var targetPackage: String = ""

    /** UUID for the current guidance session; attached to logged failures. */
    private var sessionId: String = ""

    // Auto-advance bookkeeping: a window change shortly after the user acts
    // (e.g. tapping the real button under the dot) advances to the next step.
    private var stepShownAt = 0L
    private var advancing = false

    /** Minimum dwell before a window change is allowed to advance the step. */
    private const val ADVANCE_GUARD_MS = 1200L

    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    private var activeJob: Job? = null

    /**
     * Begin guidance for [task] using the supplied thin [stepList] (demo tasks
     * and legacy callers). Steps are promoted to [StepMetadata] with safe
     * defaults. [appPackage] biases L0 matching toward the real app.
     */
    fun start(task: String, stepList: List<Step>, appPackage: String = "") {
        startMeta(task, stepList.map { PlanParser.toMetadata(it) }, appPackage)
    }

    /** Begin guidance for [task] using enriched [stepList]. */
    fun startMeta(task: String, stepList: List<StepMetadata>, appPackage: String = "") {
        if (stepList.isEmpty()) {
            Log.e(TAG, "startMeta() called with no steps.")
            return
        }
        currentTask = task
        steps = stepList
        targetPackage = appPackage.ifBlank { guessPackage(task, stepList.firstOrNull()?.findDescription ?: "") ?: "" }
        sessionId = UUID.randomUUID().toString()
        currentIndex = 0
        isRunning = true
        Log.e(TAG, "Guidance started: '$task' with ${stepList.size} steps. pkg=$targetPackage session=$sessionId")
        executeStep(0)
    }

    /**
     * Entry point for real backend calls. Fetches an enriched plan from the
     * backend via [GeminiClient], then delegates to [startMeta].
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
                val plan = GeminiClient.getEnrichedPlan(task) // calls backend /plan
                Log.e(TAG, "Backend returned ${plan.steps.size} steps, pkg=${plan.appPackage}")
                if (plan.steps.isEmpty()) {
                    withContext(Dispatchers.Main) {
                        WayloGuidanceService.instance?.speaker
                            ?.speak("Sorry, I couldn't understand that task. Please try again.")
                        isRunning = false
                    }
                    return@launch
                }
                withContext(Dispatchers.Main) {
                    startMeta(task, plan.steps, plan.appPackage)
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

        // Speak the same short instruction that is shown under the dot, so the
        // on-screen label and the voice always match.
        val spoken = shortLabel(step.instruction)
        WayloGuidanceService.instance?.speaker?.speak(step.instruction)

        stepShownAt = android.os.SystemClock.elapsedRealtime()
        advancing = false

        activeJob?.cancel()
        activeJob = scope.launch {
            val service = WayloGuidanceService.instance
            if (service == null) {
                Log.e(TAG, "No service context — cannot run guidance.")
                return@launch
            }

            // Try the pipeline, but never let it hang the loop.
            val result = withTimeoutOrNull(4000) {
                val (screenW, screenH) = screenSize(service)
                // Step 1 is almost always "find the app icon on the home screen".
                if (index == 0) {
                    val pkg = targetPackage.ifBlank { guessPackage(currentTask, step.findDescription) ?: "" }
                    val home = withContext(Dispatchers.IO) {
                        ElementFinder.findOnHomeScreen(step.findDescription, pkg.ifBlank { null })
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
                ScreenAnalysisPipeline.find(service, step, targetPackage, screenW, screenH)
            }

            withContext(Dispatchers.Main) {
                if (result != null && result.source != "failed") {
                    Log.e(TAG, "Pipeline found: ${result.source} at ${result.x},${result.y}")
                    // Show the short instruction under the dot (matches the voice).
                    OverlayManager.showDotAtResult(result, spoken)
                } else {
                    Log.e(TAG, "Pipeline (Layer 1/OCR) missed — running vision fallback.")
                    runFallback(service, index, step, spoken)
                }
            }
        }
    }

    /**
     * Layer 3 recovery: when the on-device pipeline can't find the target, call
     * the Gemini Vision fallback. It either returns coordinates (place the dot),
     * a set of recovery steps (splice them in and re-run), or a hard failure.
     */
    private suspend fun runFallback(
        service: WayloGuidanceService,
        index: Int,
        step: StepMetadata,
        spoken: String
    ) {
        val result = withContext(Dispatchers.IO) {
            FallbackHandler.handle(
                context = service,
                task = currentTask,
                stepIndex = index,
                totalSteps = steps.size,
                step = step,
                targetPackage = targetPackage,
                sessionId = sessionId
            )
        }

        when (result) {
            is FallbackHandler.FallbackResult.Found -> {
                val label = result.updatedInstruction?.let { shortLabel(it) } ?: spoken
                result.updatedInstruction?.let { service.speaker.speak(it) }
                OverlayManager.showDot(result.x, result.y, label)
            }

            is FallbackHandler.FallbackResult.NewSteps -> {
                Log.e(TAG, "Troubleshoot produced ${result.steps.size} recovery steps.")
                service.speaker.speak(result.explanation)
                // Keep completed steps, replace everything from here with recovery
                // steps (promoted to enriched metadata with safe defaults).
                steps = steps.take(index) + result.steps.map { PlanParser.toMetadata(it) }
                // Re-run the current index (now the first recovery step). A short
                // delay lets the explanation start speaking first.
                stepShownAt = android.os.SystemClock.elapsedRealtime()
                scope.launch {
                    kotlinx.coroutines.delay(1500)
                    executeStep(index)
                }
            }

            is FallbackHandler.FallbackResult.Failed -> {
                Log.e(TAG, "Fallback failed: ${result.reason}")
                service.speaker.speak(
                    "I couldn't find what I was looking for. Please scroll around or go back and try again."
                )
                // Leave a fallback dot so the user still has visual feedback.
                val wm = service.getSystemService(Context.WINDOW_SERVICE) as WindowManager
                val size = Point()
                @Suppress("DEPRECATION")
                wm.defaultDisplay.getSize(size)
                OverlayManager.showDot(size.x / 2, size.y / 3, spoken)
            }
        }
    }

    /**
     * Called by the accessibility service when the foreground window changes.
     * If enough time has passed since the current step was shown, we treat the
     * navigation as the user having acted (tapped the real button under the dot)
     * and advance to the next step. The same dot view then glides to the next
     * target for a seamless transition.
     */
    fun onWindowChanged(pkg: String) {
        if (!isRunning || advancing) return
        val elapsed = android.os.SystemClock.elapsedRealtime() - stepShownAt
        if (elapsed < ADVANCE_GUARD_MS) {
            Log.e(TAG, "onWindowChanged($pkg): ignored, only ${elapsed}ms since step shown.")
            return
        }
        advancing = true
        Log.e(TAG, "onWindowChanged($pkg): advancing to next step after ${elapsed}ms.")
        // Small delay so the new screen settles before we scan for the target.
        scope.launch {
            kotlinx.coroutines.delay(500)
            executeStep(currentIndex + 1)
        }
    }

    /** Manual advance (used by dev/demo controls). Advances one step. */
    fun onUserTappedTarget() {
        if (!isRunning) return
        Log.e(TAG, "Manual advance from step ${currentIndex + 1}.")
        executeStep(currentIndex + 1)
    }

    /**
     * Trim a full instruction to a short label suitable for the dot and TTS.
     * Keeps it readable on a small pill without truncating mid-thought.
     */
    private fun shortLabel(instruction: String): String {
        val trimmed = instruction.trim()
        return if (trimmed.length <= 40) trimmed else trimmed.take(37).trimEnd() + "…"
    }

    /** Known package names for common apps, keyed by a recognisable keyword. */
    private val KNOWN_PACKAGES = mapOf(
        "youtube" to "com.google.android.youtube",
        "whatsapp" to "com.whatsapp",
        "phonepe" to "com.phonepe.app",
        "irctc" to "com.irctc.rajdhani",
        "play store" to "com.android.vending",
        "playstore" to "com.android.vending",
        "chrome" to "com.android.chrome",
        "gmail" to "com.google.android.gm",
        "maps" to "com.google.android.apps.maps"
    )

    /**
     * Best-effort guess of the target app package for step 1, so [ElementFinder]
     * can strongly prefer the real app icon over look-alikes (e.g. the Play
     * Store listing). Matches against the task and the find description.
     */
    private fun guessPackage(task: String, findDescription: String): String? {
        val haystack = "$task $findDescription".lowercase()
        return KNOWN_PACKAGES.entries.firstOrNull { haystack.contains(it.key) }?.value
    }

    private fun taskComplete() {
        OverlayManager.hideDot()
        WayloGuidanceService.instance?.speaker?.speak("All done! Task complete.")
        isRunning = false
        Log.e(TAG, "Task complete: '$currentTask'")
    }

    /** Current display size in pixels (width, height). */
    @Suppress("DEPRECATION")
    private fun screenSize(context: Context): Pair<Int, Int> {
        val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val size = Point()
        wm.defaultDisplay.getRealSize(size)
        return Pair(size.x, size.y)
    }

    fun getCurrentStep(): StepMetadata? = steps.getOrNull(currentIndex)

    fun isActive(): Boolean = isRunning
}
