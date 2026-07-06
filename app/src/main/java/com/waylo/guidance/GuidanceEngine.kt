package com.waylo.guidance

import android.os.SystemClock
import android.util.Log
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.Toast
import com.waylo.accessibility.ElementFinder
import com.waylo.ai.GeminiClient
import com.waylo.ai.Plan
import com.waylo.ai.Step
import com.waylo.ocr.ScreenAnalysisPipeline
import com.waylo.overlay.OverlayManager
import com.waylo.service.WayloGuidanceService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Main orchestrator. Walks the user through a plan one step at a time:
 * speaks each instruction, locates the target element, places the dot on it,
 * and advances only once there is real evidence the user acted (see
 * [Verification]) — never on a fixed timer or a guess.
 *
 * Owned by the process (not an Activity), so guidance survives the user leaving
 * the Waylo app.
 */
object GuidanceEngine {

    private const val TAG = "WAYLO_DOT"

    /** Kept to honour the PRD contract (`GuidanceEngine.instance`). Self-reference. */
    var instance: GuidanceEngine? = this

    private var steps: List<Step> = emptyList()
    private var currentIndex = 0
    private var isRunning = false
    private var currentTask: String = ""

    // App package the backend resolved for this plan (enriched /plan response).
    // Null for older/cached plans or the hardcoded demo tasks; falls back to
    // the local guessPackage() heuristic in that case.
    private var currentAppPackage: String? = null

    // --- Per-step advancement bookkeeping ---

    /** When the current step's instruction was spoken. All dwell checks are relative to this. */
    private var stepShownAt = 0L

    /** When the dot was actually placed on a located target (0L while still locating). */
    private var dotShownAt = 0L

    /** Guards against a second advance signal firing while one is already in flight for this step. */
    private var advancing = false

    /** Timestamp of the last successful step advance, used to enforce [MIN_ADVANCE_INTERVAL_MS]. */
    private var lastAdvanceAt = 0L

    /** Ambiguous tap-verification signals seen for the current step (see [Verification.TapInApp]). */
    private var uncertainChecks = 0

    /** Whether the "gentle repeat" patience nudge has already fired for the current step. */
    private var hasRepeatedThisStep = false

    /** Whether the "when you see the red dot, tap it" follow-up has already been queued for the current step. */
    private var hasAnnouncedFoundThisStep = false

    /** Guards against overlapping async tap-verification lookups from a burst of content-change events. */
    private var tapEvidenceCheckInFlight = false

    /** Flipped by accessibility events to wake the locate loop early instead of waiting out its poll tick. */
    private var locateRescanRequested = false

    private var currentStepPhase: StepPhase? = null
    private var currentVerification: Verification = Verification.TapInApp

    // Set by FinancialAppGuard while a known financial app is in the
    // foreground. Never place the dot or advance steps while true.
    private var pausedForFinancialApp = false

    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    /** Job covering the whole locate+verify lifecycle of the current step; cancelling it stops all of it. */
    private var stepJob: Job? = null

    /** Scope tied to [stepJob], used by reactive event handlers to launch work scoped to the current step. */
    private var currentStepScope: CoroutineScope? = null

    // --- Pacing constants ---

    /** No advancement check runs until at least this long after the step's instruction was spoken. */
    private const val MIN_DWELL_MS = 3000L

    /** Never begin a new step less than this long after the previous advance — global rate limit. */
    private const val MIN_ADVANCE_INTERVAL_MS = 1000L

    /** Small settle delay after an advance decision, before scanning the new screen. */
    private const val SETTLE_DELAY_MS = 500L

    /** How long we patiently look for a step's target before re-speaking with the fallbackHint. */
    private const val LOCATE_TIMEOUT_MS = 30_000L

    /** If the target is found but the user hasn't acted in this long, repeat the instruction once. */
    private const val PATIENCE_MS = 15_000L

    /** Safety re-scan cadence while locating, in case a content-change event never arrives. */
    private const val RESCAN_POLL_MS = 1500L

    /** Ambiguous tap-verification signals allowed before we re-speak with the fallbackHint. */
    private const val UNCERTAIN_CHECK_LIMIT = 2

    /** Minimum ElementFinder score to trust a match enough to place the dot on it. */
    private const val ELEMENT_CONFIDENCE_FLOOR = 50

    /** Minimum ElementFinder score for a clicked/text-changed event's source node to count as "our target". */
    private const val CLICK_MATCH_FLOOR = 40

    private val OPEN_INSTRUCTION_PREFIX = Regex("^(open|launch|start)\\b", RegexOption.IGNORE_CASE)

    /** How a step's completion is detected. Chosen per-step from [Step.elementType]. */
    private sealed class Verification {
        /** APP_ICON / app-opening steps: verified by a window-state change into [expectedPackage]. */
        data class AppLaunch(val expectedPackage: String?, val fromLauncherOnly: Boolean) : Verification()

        /** TEXT_INPUT steps: verified once the target node's text becomes non-empty. */
        object TextInput : Verification()

        /** In-app taps (ICON_BUTTON/BUTTON/LIST_ITEM): verified by a click or content-change evidence. */
        object TapInApp : Verification()
    }

    private enum class StepPhase { LOCATING, WAITING_FOR_ACTION }

    /**
     * Begin guidance for [task] using the supplied [stepList]. [appPackage] is
     * the backend-resolved target app (from the enriched /plan response), if
     * known; null for demo tasks or older/cached plans.
     */
    fun start(task: String, stepList: List<Step>, appPackage: String? = null) {
        if (stepList.isEmpty()) {
            Log.e(TAG, "start() called with no steps.")
            return
        }
        currentTask = task
        steps = stepList
        currentIndex = 0
        currentAppPackage = appPackage
        isRunning = true
        lastAdvanceAt = 0L
        Log.e(TAG, "Guidance started: '$task' with ${stepList.size} steps. appPackage=$appPackage")
        executeStep(0)
    }

    /**
     * Entry point for real backend calls. Fetches a plan from the backend via
     * [GeminiClient], then delegates to the [start] overload that takes a
     * concrete step list.
     */
    fun start(task: String) {
        if (FinancialAppGuard.mentionsFinancialApp(task)) {
            Log.e(TAG, "start(): task mentions a financial app/service, refusing without calling the backend: $task")
            reportError(FinancialAppGuard.refusalMessage())
            return
        }

        if (isRunning) stop()
        isRunning = true
        currentTask = task
        currentIndex = 0
        // Defensive reset: without this, a stale/default stepShownAt (0L) makes
        // the dwell check in the event handlers below trivially pass (elapsed
        // since boot is always huge), so a window-change event that fires while
        // we're still waiting on the backend could slip through.
        // steps is cleared too so the new steps.isEmpty() guards also cover
        // repeat runs (otherwise a stale non-empty list from the previous task
        // would defeat that guard during this task's fetch).
        steps = emptyList()
        stepShownAt = android.os.SystemClock.elapsedRealtime()
        advancing = false
        lastAdvanceAt = 0L
        currentStepPhase = null
        Log.e(TAG, "GuidanceEngine.start: calling backend for task: $task")
        WayloGuidanceService.instance?.speaker?.speak("Got it. Finding the steps for you.")

        scope.launch {
            try {
                val plan = GeminiClient.getPlan(task) // calls backend /plan
                Log.e(TAG, "Backend returned ${plan.steps.size} steps, appPackage=${plan.appPackage}")
                if (plan.steps.isEmpty()) {
                    // Full technical detail to Logcat; only a short, elderly-friendly
                    // phrase gets spoken/shown to the user.
                    Log.e(TAG, "Plan fetch failed: error='${plan.error}' detail='${plan.errorDetail}'")
                    val message = friendlyErrorMessage(plan)
                    withContext(Dispatchers.Main) {
                        reportError(message)
                        isRunning = false
                    }
                    return@launch
                }
                withContext(Dispatchers.Main) {
                    start(task, plan.steps, plan.appPackage) // delegate to the existing overload
                }
            } catch (e: Exception) {
                Log.e(TAG, "Backend call failed: ${e.message}", e)
                withContext(Dispatchers.Main) {
                    reportError("Please check your internet connection and try again.")
                    isRunning = false
                }
            }
        }
    }

    /**
     * Turn a failed [Plan] into a short, elderly-friendly phrase. The raw
     * backend text ([Plan.error]/[Plan.errorDetail]) is never shown directly —
     * it's already been logged to Logcat by the caller.
     */
    private fun friendlyErrorMessage(plan: Plan): String {
        if (plan.error == GeminiClient.NETWORK_ERROR) {
            return "Please check your internet connection and try again."
        }
        val text = "${plan.error.orEmpty()} ${plan.errorDetail.orEmpty()}".lowercase()
        val isBusy = listOf("token", "quota", "rate limit", "busy", "too many", "429", "503")
            .any { text.contains(it) }
        return if (isBusy) {
            "The service is busy right now. Please try again in a few minutes."
        } else {
            "Sorry, something went wrong. Please try again."
        }
    }

    /** Speak [message] and show it as a Toast — works even after we've minimized to home. */
    private fun reportError(message: String) {
        WayloGuidanceService.instance?.let { service ->
            Toast.makeText(service, message, Toast.LENGTH_LONG).show()
            service.speaker.speak(message)
        }
    }

    /** Stop guidance, clear the dot, and silence the voice. */
    fun stop() {
        isRunning = false
        stepJob?.cancel()
        stepJob = null
        currentStepScope = null
        currentStepPhase = null
        OverlayManager.hideDot()
        WayloGuidanceService.instance?.speaker?.stop()
        Log.e(TAG, "Guidance stopped.")
    }

    /**
     * Called by [FinancialAppGuard] the moment a known financial app comes to
     * the foreground. Cancels any in-flight step work and hides the dot, but
     * keeps [steps]/[currentIndex] intact so [resumeAfterFinancialApp] can
     * pick back up where guidance left off.
     */
    fun pauseForFinancialApp() {
        if (!isRunning || pausedForFinancialApp) return
        pausedForFinancialApp = true
        stepJob?.cancel()
        currentStepScope = null
        currentStepPhase = null
        OverlayManager.hideDot()
        Log.e(TAG, "Guidance paused for financial app.")
    }

    /** Called by [FinancialAppGuard] once the user has left the financial app. */
    fun resumeAfterFinancialApp() {
        if (!pausedForFinancialApp) return
        pausedForFinancialApp = false
        Log.e(TAG, "Guidance resuming after financial app.")
        if (isRunning) executeStep(currentIndex)
    }

    /**
     * Begin step [index]: speak its instruction, decide how completion will be
     * verified (see [verificationFor]), and launch the locate-then-watch
     * lifecycle in a fresh per-step job so a later stop/pause/advance can
     * cancel every piece of in-flight work for this step in one shot.
     */
    private fun executeStep(index: Int) {
        if (!isRunning || index >= steps.size) {
            if (index >= steps.size) taskComplete()
            return
        }

        currentIndex = index
        val step = steps[index]
        Log.e(TAG, "executeStep called for index $index: ${step.instruction}")
        Log.e(TAG, "findDescription: ${step.findDescription}")

        val spoken = shortLabel(step.instruction)
        WayloGuidanceService.instance?.speaker?.speak(step.instruction)

        stepShownAt = SystemClock.elapsedRealtime()
        dotShownAt = 0L
        currentStepPhase = StepPhase.LOCATING
        currentVerification = verificationFor(index, step)
        uncertainChecks = 0
        hasRepeatedThisStep = false
        hasAnnouncedFoundThisStep = false
        tapEvidenceCheckInFlight = false
        locateRescanRequested = false
        advancing = false

        stepJob?.cancel()
        val job = Job(scope.coroutineContext[Job])
        stepJob = job
        val stepScope = CoroutineScope(scope.coroutineContext + job)
        currentStepScope = stepScope

        stepScope.launch {
            val service = WayloGuidanceService.instance
            if (service == null) {
                Log.e(TAG, "No service context — cannot run guidance.")
                return@launch
            }
            val pkg = currentAppPackage ?: guessPackage(currentTask, step.findDescription)
            locateStep(service, index, step, pkg, spoken)
        }
    }

    /**
     * Decide how step [index]'s completion will be detected:
     *  - TEXT_INPUT -> [Verification.TextInput] (target's text becomes non-empty).
     *  - APP_ICON, or step 1 from the home screen, or (for legacy plans with no
     *    elementType) an instruction that reads like "Open/Launch/Start ..." ->
     *    [Verification.AppLaunch] (window-state change into the expected app).
     *  - Everything else (ICON_BUTTON/BUTTON/LIST_ITEM, and any other/unknown
     *    type) -> [Verification.TapInApp] (click or content-change evidence).
     */
    private fun verificationFor(index: Int, step: Step): Verification {
        val type = step.elementType?.uppercase()?.trim()
        val looksLikeAppOpen = type == "APP_ICON" ||
            (type.isNullOrBlank() && OPEN_INSTRUCTION_PREFIX.containsMatchIn(step.instruction.trim()))
        return when {
            type == "TEXT_INPUT" -> Verification.TextInput
            index == 0 || looksLikeAppOpen -> {
                val expectedPackage = currentAppPackage ?: guessPackage(currentTask, step.findDescription)
                Verification.AppLaunch(expectedPackage, fromLauncherOnly = index == 0)
            }
            else -> Verification.TapInApp
        }
    }

    /**
     * The requirement-2 "don't guess" loop: repeatedly try to locate the
     * step's target on-device, and only once it clears [ELEMENT_CONFIDENCE_FLOOR]
     * do we place the dot. While not found, the dot stays hidden and we
     * re-scan on every content-change nudge (or a [RESCAN_POLL_MS] safety
     * tick). After [LOCATE_TIMEOUT_MS] with nothing found, we try the slower
     * vision fallback chain once; if that also misses, we re-speak with the
     * step's fallbackHint and open a fresh patient window rather than
     * abandoning the user mid-task.
     */
    private suspend fun locateStep(
        service: WayloGuidanceService,
        index: Int,
        step: Step,
        pkg: String?,
        spoken: String
    ) {
        var deadline = SystemClock.elapsedRealtime() + LOCATE_TIMEOUT_MS

        while (isRunning && currentIndex == index && !pausedForFinancialApp) {
            val result = locateOnDevice(index, step, pkg)
            if (result != null) {
                onTargetLocated(index, spoken, result)
                return
            }

            if (SystemClock.elapsedRealtime() >= deadline) {
                Log.e(TAG, "locateStep: on-device pipeline timed out for step $index, trying vision fallback.")
                if (tryVisionFallback(service, index, step, spoken)) return
                // Vision fallback also missed. Never guess a dot position —
                // gently re-prompt with the fallback hint and open a fresh
                // patient window instead of giving up on the user.
                Log.e(TAG, "locateStep: still not found after ${LOCATE_TIMEOUT_MS}ms, re-speaking fallbackHint.")
                speakFallbackHint(step)
                deadline = SystemClock.elapsedRealtime() + LOCATE_TIMEOUT_MS
            }

            waitForRescanTrigger()
        }
    }

    /** One cheap on-device attempt: home-screen shortcut for step 1, else the full L0+L1 pipeline. */
    private suspend fun locateOnDevice(
        index: Int,
        step: Step,
        pkg: String?
    ): ScreenAnalysisPipeline.PipelineResult? {
        val service = WayloGuidanceService.instance ?: return null

        if (index == 0) {
            val home = withContext(Dispatchers.IO) {
                ElementFinder.findOnHomeScreen(step.findDescription, pkg, step.alternateLabels)
            }
            if (home != null && home.score >= ELEMENT_CONFIDENCE_FLOOR) {
                val bounds = ElementFinder.getBoundsOnScreen(home.node)
                return ScreenAnalysisPipeline.PipelineResult(
                    x = bounds.centerX(),
                    y = bounds.centerY(),
                    source = "home-screen",
                    confidence = home.score.toFloat(),
                    label = step.findDescription
                )
            }
            // A weak/missing home-screen match falls through to the general
            // pipeline below (OCR may still catch a label the tree didn't).
        }

        // The target-package bonus in ElementFinder exists to disambiguate
        // look-alike icons on the HOME SCREEN (e.g. the real YouTube icon vs.
        // the Play Store listing) — it's meaningless once we're already
        // inside the target app, since every visible interactive node shares
        // that same package. Passing it there let content-free nodes (any
        // clickable+visible icon) clear ELEMENT_CONFIDENCE_FLOOR on the
        // package bonus alone. Only pass it for the step-1 home-screen case.
        val targetPackageForSearch = if (index == 0) pkg else null
        val result = withTimeoutOrNull(4000) {
            ScreenAnalysisPipeline.find(
                service,
                step.findDescription,
                targetPackageForSearch,
                step.alternateLabels,
                step.visualDescription
            )
        }
        return if (result != null && result.source != "failed") result else null
    }

    /** Wait for a content-change nudge, or [RESCAN_POLL_MS] as a safety fallback. */
    private suspend fun waitForRescanTrigger() {
        val start = SystemClock.elapsedRealtime()
        while (isRunning && SystemClock.elapsedRealtime() - start < RESCAN_POLL_MS) {
            if (locateRescanRequested) {
                locateRescanRequested = false
                return
            }
            delay(150)
        }
        locateRescanRequested = false
    }

    /**
     * The target cleared the confidence floor: show the dot, tell the user to
     * tap it, and switch into the WAITING_FOR_ACTION phase where the
     * accessibility-event handlers below take over verification.
     *
     * The full instruction was already spoken (flushing) at the start of the
     * step in [executeStep] — this follow-up MUST use [speakQueued], not
     * [speak]/QUEUE_FLUSH, or it cancels that instruction mid-sentence
     * whenever the target is found quickly (the common case: on-device
     * matches often resolve in under 100ms, well before a multi-second
     * instruction finishes playing). Guarded to fire at most once per step.
     */
    private fun onTargetLocated(index: Int, spoken: String, result: ScreenAnalysisPipeline.PipelineResult) {
        if (!isRunning || currentIndex != index) return
        Log.e(TAG, "Target located for step ${index + 1}: source=${result.source} confidence=${result.confidence}")
        OverlayManager.showDotAtResult(result, spoken)
        if (!hasAnnouncedFoundThisStep) {
            hasAnnouncedFoundThisStep = true
            WayloGuidanceService.instance?.speaker?.speakQueued("When you see the red dot, tap it.")
        }
        dotShownAt = SystemClock.elapsedRealtime()
        currentStepPhase = StepPhase.WAITING_FOR_ACTION
        uncertainChecks = 0
        hasRepeatedThisStep = false
        schedulePatienceCheck(index)
        if (currentVerification is Verification.TextInput) {
            launchInStep { pollTextInput(index) }
        }
    }

    /** Gently repeat the instruction once if the user hasn't acted [PATIENCE_MS] after the dot appeared. */
    private fun schedulePatienceCheck(index: Int) {
        launchInStep {
            delay(PATIENCE_MS)
            if (isRunning && currentIndex == index &&
                currentStepPhase == StepPhase.WAITING_FOR_ACTION && !hasRepeatedThisStep
            ) {
                hasRepeatedThisStep = true
                Log.e(TAG, "Patience timeout on step $index — repeating instruction once.")
                steps.getOrNull(index)?.let { WayloGuidanceService.instance?.speaker?.speak(it.instruction) }
            }
        }
    }

    /** TEXT_INPUT backup: poll the live tree in case TYPE_VIEW_TEXT_CHANGED never fires for this keyboard/field. */
    private suspend fun pollTextInput(index: Int) {
        while (isRunning && currentIndex == index && currentStepPhase == StepPhase.WAITING_FOR_ACTION) {
            delay(1000)
            if (!isRunning || currentIndex != index || currentStepPhase != StepPhase.WAITING_FOR_ACTION) return
            if (SystemClock.elapsedRealtime() - stepShownAt < MIN_DWELL_MS) continue
            val step = steps.getOrNull(index) ?: return
            // No targetPackage here: this only ever runs once we're already
            // confirmed inside the target app (never step 0), where every
            // node shares that package and the bonus adds noise, not signal.
            val match = withContext(Dispatchers.IO) {
                ElementFinder.findElement(step.findDescription, null, step.alternateLabels)
            }
            if (!isRunning || currentIndex != index || currentStepPhase != StepPhase.WAITING_FOR_ACTION) return
            if (match != null && !match.node.text.isNullOrBlank()) {
                Log.e(TAG, "pollTextInput: text became non-empty, advancing.")
                advanceFrom(index)
                return
            }
        }
    }

    /**
     * Layer 3 recovery: when the on-device pipeline can't find the target after
     * a full patient window, call the Gemini Vision fallback chain (also tries
     * OCR/YOLO again first). Found -> place the dot; NewSteps -> splice
     * recovery steps in and restart; Failed -> report back so the caller can
     * keep waiting instead of guessing a position.
     */
    private suspend fun tryVisionFallback(
        service: WayloGuidanceService,
        index: Int,
        step: Step,
        spoken: String
    ): Boolean {
        val result = FallbackHandler.handle(
            context = service,
            task = currentTask,
            stepIndex = index,
            totalSteps = steps.size,
            findDesc = step.findDescription,
            alternateLabels = step.alternateLabels,
            visualDescription = step.visualDescription,
            instruction = step.instruction,
            screenRegion = step.screenRegion
        )

        return when (result) {
            is FallbackHandler.FallbackResult.Found -> {
                val label = result.updatedInstruction?.let { shortLabel(it) } ?: spoken
                result.updatedInstruction?.let { service.speaker.speak(it) }
                onTargetLocated(
                    index,
                    label,
                    ScreenAnalysisPipeline.PipelineResult(result.x, result.y, "vision", 100f, label)
                )
                true
            }

            is FallbackHandler.FallbackResult.NewSteps -> {
                Log.e(TAG, "Troubleshoot produced ${result.steps.size} recovery steps.")
                service.speaker.speak(result.explanation)
                // Keep completed steps, replace everything from here with recovery steps.
                steps = steps.take(index) + result.steps
                // Re-run the current index (now the first recovery step) on the
                // top-level scope — not launchInStep — since executeStep() is
                // about to replace stepJob entirely.
                scope.launch {
                    delay(1500)
                    executeStep(index)
                }
                true
            }

            is FallbackHandler.FallbackResult.Failed -> {
                Log.e(TAG, "Vision fallback failed: ${result.reason}")
                false
            }
        }
    }

    /**
     * Called by the accessibility service on TYPE_WINDOW_STATE_CHANGED. Only
     * [Verification.AppLaunch] steps advance on this signal — verified against
     * the expected package (or, for step 1, simply leaving the launcher).
     * Also nudges the locate loop to retry immediately, since a window change
     * may have just revealed the current step's target.
     */
    fun onWindowStateChanged(pkg: String) {
        if (!isRunning || steps.isEmpty() || pausedForFinancialApp) return
        locateRescanRequested = true

        if (currentStepPhase != StepPhase.WAITING_FOR_ACTION) return
        val verification = currentVerification as? Verification.AppLaunch ?: return

        val elapsed = SystemClock.elapsedRealtime() - stepShownAt
        if (elapsed < MIN_DWELL_MS) {
            Log.e(TAG, "onWindowStateChanged($pkg): ignored, only ${elapsed}ms since step shown.")
            return
        }

        val matched = when {
            verification.fromLauncherOnly ->
                !ElementFinder.isLauncherPackage(pkg) &&
                    (verification.expectedPackage == null || pkg == verification.expectedPackage)
            verification.expectedPackage != null -> pkg == verification.expectedPackage
            else -> true // no known expected package — best-effort: any navigation counts
        }
        if (!matched) {
            Log.e(TAG, "onWindowStateChanged($pkg): doesn't match expected app (${verification.expectedPackage}).")
            return
        }

        Log.e(TAG, "onWindowStateChanged($pkg): app-launch verified, advancing.")
        advanceFrom(currentIndex)
    }

    /**
     * Called by the accessibility service on TYPE_WINDOW_CONTENT_CHANGED.
     * Feeds the tap-in-app verification check and nudges the locate loop.
     */
    fun onContentChanged(pkg: String) {
        if (!isRunning || steps.isEmpty() || pausedForFinancialApp) return
        locateRescanRequested = true

        if (currentStepPhase != StepPhase.WAITING_FOR_ACTION) return
        if (currentVerification !is Verification.TapInApp) return
        // Ignore content changes from outside the target app (status bar clock
        // ticks, notification shade, etc.) — only the app we're guiding through
        // is relevant evidence for a same-app tap.
        if (currentAppPackage != null && pkg != currentAppPackage) return
        checkTapInAppEvidence(currentIndex, viaClick = false, clickedNode = null)
    }

    /** Called by the accessibility service on TYPE_VIEW_CLICKED. */
    fun onViewClicked(sourceNode: AccessibilityNodeInfo?) {
        if (!isRunning || steps.isEmpty() || pausedForFinancialApp) return
        if (currentStepPhase != StepPhase.WAITING_FOR_ACTION) return
        if (currentVerification !is Verification.TapInApp) return
        checkTapInAppEvidence(currentIndex, viaClick = true, clickedNode = sourceNode)
    }

    /**
     * Tap-in-app verification (rule c): advance if the clicked node matches
     * our target, or if a content-change shows the target gone / the next
     * step's target already up. Anything else is ambiguous; after
     * [UNCERTAIN_CHECK_LIMIT] ambiguous checks we re-speak with the
     * fallbackHint instead of advancing.
     */
    private fun checkTapInAppEvidence(index: Int, viaClick: Boolean, clickedNode: AccessibilityNodeInfo?) {
        val elapsed = SystemClock.elapsedRealtime() - stepShownAt
        if (elapsed < MIN_DWELL_MS) return
        val step = steps.getOrNull(index) ?: return

        if (viaClick && clickedNode != null) {
            val score = ElementFinder.scoreNode(clickedNode, step.findDescription)
            if (score >= CLICK_MATCH_FLOOR) {
                Log.e(TAG, "checkTapInAppEvidence: clicked node matches target (score=$score), advancing.")
                advanceFrom(index)
                return
            }
        }

        // Android can fire many TYPE_WINDOW_CONTENT_CHANGED events per second
        // during a scroll/transition animation; onContentChanged() calls this
        // for every one of them. Without this guard, each event spawned its
        // own concurrent findElement() pair (tens of duplicate scans observed
        // in one capture within a few hundred ms). Coalesce to at most one
        // outstanding lookup — a stale-in-flight check will be superseded by
        // the next event anyway once it finishes.
        if (tapEvidenceCheckInFlight) return
        tapEvidenceCheckInFlight = true

        val launched = launchInStep {
            try {
                // No targetPackage here either — same reasoning as
                // pollTextInput above: every node in the current screen
                // already shares this app's package, so the bonus can only
                // add noise, not discriminate the real target.
                val stillThere = withContext(Dispatchers.IO) {
                    ElementFinder.findElement(step.findDescription, null, step.alternateLabels)
                }
                val nextStep = steps.getOrNull(index + 1)
                val nextAppeared = nextStep?.let { next ->
                    withContext(Dispatchers.IO) {
                        ElementFinder.findElement(next.findDescription, null, next.alternateLabels)
                    }
                }
                if (currentIndex != index || currentStepPhase != StepPhase.WAITING_FOR_ACTION) return@launchInStep

                val targetGone = stillThere == null || stillThere.score < ELEMENT_CONFIDENCE_FLOOR
                val nextIsUp = nextAppeared != null && nextAppeared.score >= ELEMENT_CONFIDENCE_FLOOR

                when {
                    nextIsUp || (targetGone && viaClick) -> {
                        Log.e(
                            TAG,
                            "checkTapInAppEvidence: confirmed (${if (nextIsUp) "next target appeared" else "target gone + click"})."
                        )
                        advanceFrom(index)
                    }
                    targetGone -> {
                        uncertainChecks++
                        Log.e(TAG, "checkTapInAppEvidence: ambiguous (#$uncertainChecks) for step $index.")
                        if (uncertainChecks >= UNCERTAIN_CHECK_LIMIT) {
                            uncertainChecks = 0
                            speakFallbackHint(step)
                        }
                    }
                    else -> Unit // target still clearly present — nothing changed, keep waiting.
                }
            } finally {
                tapEvidenceCheckInFlight = false
            }
        }
        if (launched == null) tapEvidenceCheckInFlight = false // no step scope to run in (race with stop/advance)
    }

    /**
     * Called by the accessibility service on TYPE_VIEW_TEXT_CHANGED. Advances
     * a TEXT_INPUT step once the target's text is non-empty (belt-and-braces
     * with [pollTextInput], since not every keyboard/IME fires this reliably).
     */
    fun onTextChanged(sourceNode: AccessibilityNodeInfo?) {
        if (!isRunning || steps.isEmpty() || pausedForFinancialApp) return
        if (currentStepPhase != StepPhase.WAITING_FOR_ACTION) return
        if (currentVerification !is Verification.TextInput) return

        val elapsed = SystemClock.elapsedRealtime() - stepShownAt
        if (elapsed < MIN_DWELL_MS) return

        val index = currentIndex
        val step = steps.getOrNull(index) ?: return

        val text = sourceNode?.text?.toString()
        val looksLikeOurTarget = sourceNode != null &&
            ElementFinder.scoreNode(sourceNode, step.findDescription) >= CLICK_MATCH_FLOOR
        if (looksLikeOurTarget && !text.isNullOrBlank()) {
            Log.e(TAG, "onTextChanged: target text became non-empty, advancing.")
            advanceFrom(index)
            return
        }

        // The event may have fired on a sibling/wrapper rather than the exact
        // node ElementFinder would pick — re-resolve from the live tree. No
        // targetPackage: we're always already inside the target app here.
        launchInStep {
            val match = withContext(Dispatchers.IO) {
                ElementFinder.findElement(step.findDescription, null, step.alternateLabels)
            }
            if (currentIndex == index && currentStepPhase == StepPhase.WAITING_FOR_ACTION &&
                match != null && !match.node.text.isNullOrBlank()
            ) {
                Log.e(TAG, "onTextChanged: re-resolved target now has text, advancing.")
                advanceFrom(index)
            }
        }
    }

    /**
     * The single, rate-limited path to the next step. Enforces
     * [MIN_ADVANCE_INTERVAL_MS] (never more than one advance per second) and
     * [SETTLE_DELAY_MS] before scanning the new screen. [advancing] guards
     * against two verification signals firing for the same step.
     */
    private fun advanceFrom(index: Int) {
        if (!isRunning || currentIndex != index || advancing) return
        advancing = true
        currentStepPhase = null // stop reacting to further signals for this step immediately
        Log.e(TAG, "advanceFrom($index): verified, advancing to step ${index + 2}.")
        scope.launch {
            val now = SystemClock.elapsedRealtime()
            val sinceLastAdvance = now - lastAdvanceAt
            if (sinceLastAdvance < MIN_ADVANCE_INTERVAL_MS) {
                delay(MIN_ADVANCE_INTERVAL_MS - sinceLastAdvance)
            }
            lastAdvanceAt = SystemClock.elapsedRealtime()
            delay(SETTLE_DELAY_MS) // let the new screen settle before scanning for the next target
            executeStep(index + 1)
        }
    }

    /** Launch [block] scoped to the current step's job, so stop/pause/advance cancel it automatically. */
    private fun launchInStep(block: suspend CoroutineScope.() -> Unit): Job? =
        currentStepScope?.launch(block = block)

    /** Speak the instruction again together with the backend's fallbackHint, without advancing. */
    private fun speakFallbackHint(step: Step) {
        val hint = step.fallbackHint?.takeIf { it.isNotBlank() }
        val message = if (hint != null) "${step.instruction}. $hint" else step.instruction
        WayloGuidanceService.instance?.speaker?.speak(message)
    }

    /** Manual advance (used by dev/demo controls). Goes through the same rate-limited path as any other signal. */
    fun onUserTappedTarget() {
        if (!isRunning) return
        Log.e(TAG, "Manual advance from step ${currentIndex + 1}.")
        advanceFrom(currentIndex)
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

    /** Only reachable via [advanceFrom] on the verified last step — never a bare timeout. */
    private fun taskComplete() {
        stepJob?.cancel()
        stepJob = null
        currentStepScope = null
        currentStepPhase = null
        OverlayManager.hideDot()
        WayloGuidanceService.instance?.speaker?.speak("All done! Task complete.")
        isRunning = false
        Log.e(TAG, "Task complete: '$currentTask'")
    }

    fun getCurrentStep(): Step? = steps.getOrNull(currentIndex)

    fun isActive(): Boolean = isRunning
}
