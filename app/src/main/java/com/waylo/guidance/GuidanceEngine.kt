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
import com.waylo.overlay.ArrowView
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

    /** Unique per guidance session — tags every /failure report (detection misses, corrections, success pairs) so they can be grouped/replayed together. */
    private var sessionId: String = java.util.UUID.randomUUID().toString()

    // App package the backend resolved for this plan (enriched /plan response).
    // Null for older/cached plans or the hardcoded demo tasks; falls back to
    // the local guessPackage() heuristic in that case.
    private var currentAppPackage: String? = null

    /**
     * Bumped every time a new guidance session actually begins (see
     * [start]). advanceFrom()/checkLookaheadSkip()/tryVisionFallback()'s
     * NewSteps recovery all schedule their `executeStep()` continuation on
     * the top-level [scope] rather than [currentStepScope] (deliberately —
     * `executeStep()` cancels `stepJob`, so scheduling on a scope tied to
     * that job risks the continuation cancelling itself mid-call). That
     * means those continuations are NOT cancelled by [stop]/[taskComplete].
     * Each one captures the generation at schedule-time and checks it still
     * matches at fire-time, so a stale continuation from a task that already
     * ended (or was superseded by a new one started in the meantime) can't
     * resurrect it or hijack a newer task's steps.
     */
    private var taskGeneration = 0

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

    /** Guards against overlapping async tap-verification lookups from a burst of content-change events. */
    private var tapEvidenceCheckInFlight = false

    /**
     * The package name from the most recent TYPE_WINDOW_STATE_CHANGED/
     * TYPE_WINDOW_CONTENT_CHANGED event — i.e. our best signal for "what's
     * actually in the foreground right now". Updated unconditionally
     * (before the isRunning/etc. guards) in [onWindowStateChanged]/
     * [onContentChanged] so it's fresh the moment guidance needs it, and
     * persists across steps (this is a continuous signal, not per-step
     * state — only [hasAnnouncedWrongApp] resets per step).
     */
    private var lastKnownForegroundPackage: String? = null

    /** Whether the "this isn't the right place" nudge has already been said for the CURRENT excursion out of the expected app. Reset per-step, and again as soon as the user's back in the expected app (so a second excursion gets its own one-time nudge). */
    private var hasAnnouncedWrongApp = false

    /** What's currently under the dot for this step, so periodic re-validation can tell if it's gone or beaten. */
    private var placedResult: ScreenAnalysisPipeline.PipelineResult? = null

    /** Flipped by accessibility events to wake the locate loop early instead of waiting out its poll tick. */
    private var locateRescanRequested = false

    /**
     * Debounce for [checkLookaheadSkip]: the step index it saw confidently
     * present on the PREVIOUS check. A skip only commits once the SAME
     * target is confirmed on two consecutive checks — device testing showed
     * a single transient/flickery match (score cleared isConfident for one
     * scan, then vanished on the very next real search) could otherwise
     * hijack a step instantly, before its own on-device/partial-match/vision
     * escalation ever got a chance to run. Reset per-step in [executeStep].
     */
    private var pendingSkipTargetIndex: Int? = null

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

    /**
     * Shorter patient window used instead of [LOCATE_TIMEOUT_MS] for steps
     * [looksLikeImageOnlyTarget] flags — image-only elements (e.g. a round
     * profile picture) routinely carry no text/contentDescription at all, so
     * the tree/OCR layers can never confidently find them and waiting the
     * full 30s before trying partial-match/YOLO/vision just delays the
     * layers actually capable of finding them.
     */
    private const val IMAGE_ONLY_LOCATE_TIMEOUT_MS = 6_000L

    /** If the target is found but the user hasn't acted in this long, repeat the instruction once. */
    private const val PATIENCE_MS = 15_000L

    /** Safety re-scan cadence while locating, in case a content-change event never arrives. */
    private const val RESCAN_POLL_MS = 1500L

    /** Ambiguous tap-verification signals allowed before we re-speak with the fallbackHint. */
    private const val UNCERTAIN_CHECK_LIMIT = 2

    /** Minimum ElementFinder score for a clicked/text-changed event's source node to count as "our target". */
    private const val CLICK_MATCH_FLOOR = 40

    /** How often an already-placed dot is re-checked against a fresh scan while waiting for the user to act. */
    private const val REVALIDATE_INTERVAL_MS = 4000L

    /** A fresh candidate must land at least this far (px) from the current dot before it's worth moving. */
    private const val MOVED_DISTANCE_PX = 60

    /**
     * How many steps ahead to check for a screen-aware skip (see
     * [checkLookaheadSkip]). Bounded deliberately small — this is a recovery
     * for a stale/hallucinated *nearby* plan step, not a general-purpose
     * planner; scanning the whole remaining plan would risk jumping to a
     * target that merely looks similar much later in an unrelated flow.
     */
    private const val LOOKAHEAD_STEPS = 3

    /** Delay after a spoken skip/partial-match announcement before acting on it, so TTS isn't cut off mid-sentence. */
    private const val ANNOUNCEMENT_SETTLE_MS = 1500L

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
        sessionId = java.util.UUID.randomUUID().toString()
        taskGeneration++ // invalidates any stale advanceFrom/checkLookaheadSkip/vision-recovery continuation still pending from a previous session
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

    /** Stop guidance, clear the dot/arrow, and silence the voice. */
    fun stop() {
        if (!isRunning) return // idempotent — a repeat call (e.g. the dev-tool Stop button pressed twice) is a no-op
        isRunning = false
        stepJob?.cancel()
        stepJob = null
        currentStepScope = null
        currentStepPhase = null
        OverlayManager.hideDot()
        OverlayManager.hideArrow()
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
        OverlayManager.hideArrow()
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

        // A dot placed for a PREVIOUS step (or one that never got confirmed)
        // must never linger into this step's search — e.g. if this step's
        // target is never found, the last step's dot must not just sit there
        // looking like current guidance. onTargetLocated() re-shows it once
        // (and only once) this step's own target is confirmed.
        OverlayManager.hideDot()

        // If this step's own instruction/fallbackHint implies scrolling or
        // swiping (e.g. "swipe up to see more apps"), show a directional
        // arrow instead of nothing while we search — onTargetLocated()
        // switches it out for the dot the moment the target actually
        // resolves. Steps that don't imply a gesture get no arrow.
        val scrollDirection = impliedScrollDirection(step)
        if (scrollDirection != null) {
            OverlayManager.showArrow(scrollDirection)
        } else {
            OverlayManager.hideArrow()
        }

        stepShownAt = SystemClock.elapsedRealtime()
        dotShownAt = 0L
        currentStepPhase = StepPhase.LOCATING
        currentVerification = verificationFor(index, step)
        placedResult = null
        uncertainChecks = 0
        hasRepeatedThisStep = false
        tapEvidenceCheckInFlight = false
        locateRescanRequested = false
        pendingSkipTargetIndex = null
        hasAnnouncedWrongApp = false
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
     * step's target on-device, and only once it clears
     * [ElementFinder.MatchResult.isConfident] do we place the dot. While not
     * found, the dot stays hidden and we re-scan on every content-change
     * nudge (or a [RESCAN_POLL_MS] safety tick). After [LOCATE_TIMEOUT_MS]
     * with nothing found, we try the slower vision fallback chain once; if
     * that also misses, we re-speak with the step's fallbackHint and open a
     * fresh patient window rather than abandoning the user mid-task.
     */
    private suspend fun locateStep(
        service: WayloGuidanceService,
        index: Int,
        step: Step,
        pkg: String?,
        spoken: String
    ) {
        // Image-only targets (e.g. a round profile picture) routinely carry
        // no text/contentDescription the tree/OCR layers can match at all —
        // waiting the full patient window before trying partial-match/YOLO/
        // vision just delays the layers actually capable of finding them.
        val timeoutMs = if (looksLikeImageOnlyTarget(step)) IMAGE_ONLY_LOCATE_TIMEOUT_MS else LOCATE_TIMEOUT_MS
        // Anchored to stepShownAt (when this step first began), NOT to
        // "now" — locateStep() can be re-entered mid-step by
        // revalidatePlacement() (a placement briefly found then lost), and
        // that must NOT hand the step a brand-new full patient window each
        // time. Device testing showed a step whose search kept getting
        // reset this way (a borderline on-device match found, then
        // invalidated a few seconds later, repeatedly) never actually
        // reached its deadline across 3 separate captures — partial-match/
        // vision/YOLO were never once exercised as a result. Only the
        // "opened a fresh patient window after a full escalation attempt"
        // reset below anchors to "now", since that's a genuinely new window
        // after already trying everything once.
        var deadline = stepShownAt + timeoutMs

        while (isRunning && currentIndex == index && !pausedForFinancialApp) {
            // Never search (or place/reference the dot) while the user is
            // somewhere other than this step's expected app — that's not a
            // "target hard to find" problem, and a stray match from the
            // wrong screen must never get placed. Wait here until a window
            // change brings them back, rather than burning the patient
            // window on a screen we already know is wrong.
            if (!isInExpectedApp(index)) {
                handleWrongApp()
                waitForRescanTrigger()
                continue
            }
            hasAnnouncedWrongApp = false // back on track — a future excursion gets its own one-time nudge

            val result = locateOnDevice(index, step, pkg)
            if (result != null) {
                onTargetLocated(index, step, spoken, result)
                return
            }

            // Screen-aware step skipping (only reached when the on-device
            // search just above came up empty for THIS step this scan — a
            // confidently-present current-step target always returns above
            // and never reaches here).
            if (checkLookaheadSkip(index) != null) return

            if (SystemClock.elapsedRealtime() >= deadline) {
                Log.e(TAG, "locateStep: on-device pipeline timed out for step $index, trying a lowered-confidence partial match.")
                if (tryPartialMatchAcceptance(index, step, pkg)) return

                Log.e(TAG, "locateStep: no partial match either, trying vision fallback.")
                if (tryVisionFallback(service, index, step, spoken)) return
                // Vision fallback also missed. Never guess a dot position —
                // gently re-prompt with the fallback hint and open a fresh
                // patient window instead of giving up on the user.
                Log.e(TAG, "locateStep: still not found after ${timeoutMs}ms, re-speaking fallbackHint.")
                speakFallbackHint(step)
                deadline = SystemClock.elapsedRealtime() + timeoutMs
            }

            waitForRescanTrigger()
        }
    }

    /**
     * Requirement: real-world plans are sometimes stale/hallucinated about
     * the target app's current UI (e.g. a plan routing through Settings >
     * Manage History when a "History" item is already directly on screen).
     * On every re-scan where step [index]'s own target wasn't found this
     * pass, ALSO score the next [LOOKAHEAD_STEPS] steps' targets against the
     * SAME accessibility-tree snapshot in one call (cheap: one extra tree
     * walk total, no OCR/vision) — if the closest of them is confidently
     * present, jump straight there instead of continuing to hunt for a step
     * that may not reflect the real screen.
     *
     * Only ever looks forward (steps are examined in index order starting at
     * `index + 1`, closest first — backwards is structurally impossible
     * here) and only ever called after the caller has already established
     * this scan's current-step search came up empty, so a confidently-present
     * current-step target is never skipped past.
     *
     * Every decision is logged with both steps' descriptions and the full
     * set of lookahead scores considered, tagged `STEP_SKIP` for later audit.
     *
     * Debounced via [pendingSkipTargetIndex]: a skip only commits once the
     * SAME target has been confidently seen on two consecutive checks, and
     * only once at least [MIN_DWELL_MS] has passed since the step was shown
     * — device testing showed a single transient match (present for one
     * scan, gone on the very next) could otherwise hijack a step within tens
     * of milliseconds, before its own on-device/partial-match/vision
     * escalation ever got a chance to run.
     *
     * @return the absolute step index jumped to, or null if no lookahead step
     * qualified (the caller's normal timeout/vision-fallback path continues).
     */
    private fun checkLookaheadSkip(index: Int): Int? {
        if (!isRunning || currentIndex != index || pausedForFinancialApp) return null
        if (SystemClock.elapsedRealtime() - stepShownAt < MIN_DWELL_MS) return null

        val lookahead = ((index + 1)..(index + LOOKAHEAD_STEPS))
            .mapNotNull { i -> steps.getOrNull(i)?.let { i to it } }
        if (lookahead.isEmpty()) return null

        val queries = lookahead.map { (_, s) -> ElementFinder.ElementQuery(s.findDescription, s.alternateLabels) }
        val matches = ElementFinder.scanMultiple(queries)
        val scoreLog = lookahead.indices.joinToString(", ") { i ->
            val (stepIdx, _) = lookahead[i]
            "step${stepIdx + 1}=${matches[i]?.score ?: "none"}"
        }

        for (i in lookahead.indices) {
            val (targetIndex, targetStep) = lookahead[i]
            val match = matches[i] ?: continue
            if (!match.isConfident()) continue

            if (pendingSkipTargetIndex != targetIndex) {
                pendingSkipTargetIndex = targetIndex
                Log.e(
                    TAG,
                    "STEP_SKIP_PENDING: step ${index + 1} -> step ${targetIndex + 1} " +
                        "(score=${match.score}) seen once, confirming next scan before jumping."
                )
                return null
            }

            Log.e(
                TAG,
                "STEP_SKIP: step ${index + 1} ('${steps[index].findDescription}') not found this scan; " +
                    "jumping to step ${targetIndex + 1} (target='${targetStep.findDescription}', " +
                    "score=${match.score}, runnerUp=${match.runnerUpScore}); lookahead scan=[$scoreLog]"
            )
            val label = visibleLabelFor(match, targetStep.findDescription)
            WayloGuidanceService.instance?.speaker?.speak("I can see $label already — let's go there.")
            val myGeneration = taskGeneration
            scope.launch {
                delay(ANNOUNCEMENT_SETTLE_MS)
                if (taskGeneration != myGeneration) return@launch // stale — a newer session started while this was pending
                executeStep(targetIndex)
            }
            return targetIndex
        }
        pendingSkipTargetIndex = null // this scan saw nothing confident — clear any pending candidate from a previous scan
        // No lookahead step qualified — still leave a trace (a distinct tag
        // from an actual skip) so a capture can show whether this even ran
        // and what it saw. Device testing showed actual STEP_SKIP jumps can
        // go missing from logcat under heavy system-log volume (this app's
        // own getAllNodes() debug dump alone is a big contributor); this
        // makes "checked, found nothing confident" auditable too, not just
        // "checked, jumped".
        Log.e(TAG, "STEP_SKIP_SCAN: step ${index + 1} — no confident lookahead match; scores=[$scoreLog]")
        return null
    }

    /**
     * Requirement: rather than escalate straight to the slower/paid vision
     * fallback — or worse, loop on the fallbackHint forever — once step
     * [index]'s primary findDescription search has had its entire patient
     * window and found nothing, try one more instant on-device check against
     * the step's semantic-goal hints (alternateLabels/visualDescription) via
     * [ElementFinder.findPartialMatch]. Accepts with an explicit
     * lowered-confidence announcement so the user knows this placement is a
     * best guess, not a confirmed match. Logged (tagged `PARTIAL_MATCH`) for
     * the same later-audit reason as [checkLookaheadSkip].
     *
     * @return true if a partial match was accepted (dot placed, phase moved
     * to WAITING_FOR_ACTION via [onTargetLocated]) — caller should stop
     * looping. False if nothing qualified — caller proceeds to vision fallback.
     */
    private fun tryPartialMatchAcceptance(index: Int, step: Step, pkg: String?): Boolean {
        if (!isRunning || currentIndex != index || pausedForFinancialApp) return false

        val targetPackageForSearch = if (index == 0) pkg else null
        val match = ElementFinder.findPartialMatch(step.alternateLabels, step.visualDescription, targetPackageForSearch)
            ?: return false

        Log.e(
            TAG,
            "PARTIAL_MATCH: step ${index + 1} ('${step.findDescription}') not found after the full patient window; " +
                "accepting lowered-confidence match via alternateLabels/visualDescription " +
                "(score=${match.score}, runnerUp=${match.runnerUpScore})."
        )
        val label = visibleLabelFor(match, step.findDescription)
        WayloGuidanceService.instance?.speaker?.speak("I'm not completely sure, but I think this might be it — let's try here.")
        val bounds = ElementFinder.getBoundsOnScreen(match.node)
        val result = ScreenAnalysisPipeline.PipelineResult(
            x = bounds.centerX(),
            y = bounds.centerY(),
            source = "partial-match",
            confidence = match.score.toFloat(),
            label = label
        )
        onTargetLocated(index, step, shortLabel(step.instruction), result)
        return true
    }

    /** Prefer the matched node's own visible text/contentDescription (what the user actually sees) over the backend's findDescription. */
    private fun visibleLabelFor(match: ElementFinder.MatchResult, fallback: String): String {
        val text = match.node.text?.toString()?.trim()
        if (!text.isNullOrBlank()) return text
        val desc = match.node.contentDescription?.toString()?.trim()
        if (!desc.isNullOrBlank()) return desc
        return fallback
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
            if (home != null && home.isConfident()) {
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
        // clickable+visible icon) clear the confidence floor on the package
        // bonus alone. Only pass it for the step-1 home-screen case.
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
     * The target cleared the confidence floor: show the dot and switch into
     * the WAITING_FOR_ACTION phase where the accessibility-event handlers
     * below take over verification.
     *
     * Speech policy: the step's instruction (already spoken once, flushing,
     * at the start of the step in [executeStep] — it already references the
     * red dot per the plan's own phrasing, e.g. "Look for the red dot on
     * your profile picture and tap it.") is the ONLY announcement for
     * finding the target. There is deliberately no separate "tap it" /
     * "when you see the red dot" follow-up here, and none on re-scan,
     * revalidation, or the dot moving — repeating that got noisy fast.
     * Total speech per step is: the instruction once, at most one gentle
     * idle nudge ([schedulePatienceCheck]), and the fallbackHint if truly
     * stuck ([speakFallbackHint]) — nothing else.
     */
    private fun onTargetLocated(index: Int, step: Step, spoken: String, result: ScreenAnalysisPipeline.PipelineResult) {
        if (!isRunning || currentIndex != index) return
        Log.e(TAG, "Target located for step ${index + 1}: source=${result.source} confidence=${result.confidence}")
        // The target resolved — if a scroll/swipe arrow was showing while we
        // searched, switch it out for the dot on the actual target now.
        OverlayManager.hideArrow()
        OverlayManager.showDotAtResult(result, spoken)
        placedResult = result
        dotShownAt = SystemClock.elapsedRealtime()
        currentStepPhase = StepPhase.WAITING_FOR_ACTION
        uncertainChecks = 0
        hasRepeatedThisStep = false
        schedulePatienceCheck(index)
        launchInStep { revalidatePlacement(index, step) }
        if (currentVerification is Verification.TextInput) {
            launchInStep { pollTextInput(index) }
        }
    }

    /**
     * Periodically re-checks an already-placed dot while waiting for the user
     * to act on it, so a stale or wrong placement can't sit there forever:
     *  - If the target can no longer be confirmed at all, hide the dot and
     *    hand back to [locateStep] to re-scan/re-place (and, if it drags on,
     *    escalate to the vision fallback) exactly like the initial search.
     *  - If a confident match now sits at a meaningfully different position,
     *    quietly move the dot there — no re-announcement, since this is a
     *    correction, not a new guidance moment.
     *  - Otherwise, do nothing; most ticks should be a no-op.
     */
    private suspend fun revalidatePlacement(index: Int, step: Step) {
        while (isRunning && currentIndex == index && currentStepPhase == StepPhase.WAITING_FOR_ACTION) {
            delay(REVALIDATE_INTERVAL_MS)
            if (!isRunning || currentIndex != index || currentStepPhase != StepPhase.WAITING_FOR_ACTION) return

            val pkg = if (index == 0) (currentAppPackage ?: guessPackage(currentTask, step.findDescription)) else null

            // The user may have wandered into a different app entirely while
            // the dot sat waiting for a tap — the dot must not stay visible
            // in that case (see locateStep()'s matching gate). Park it and
            // drop back to LOCATING, where that same gate takes over.
            if (!isInExpectedApp(index)) {
                Log.e(TAG, "revalidatePlacement: step $index — no longer in the expected app, parking dot.")
                OverlayManager.hideDot()
                placedResult = null
                currentStepPhase = StepPhase.LOCATING
                val service = WayloGuidanceService.instance ?: return
                locateStep(service, index, step, pkg, shortLabel(step.instruction))
                return
            }

            // Screen-aware step skipping also applies here, deliberately
            // WITHOUT gating on the current target being absent (unlike the
            // LOCATING-phase call in locateStep()): device testing showed the
            // dot can stay confidently "confirmed" on this step's target
            // (e.g. a screen title that still matches) even after the user
            // has already moved to a screen where a LATER step's target is
            // also directly visible (e.g. YouTube's Settings screen title
            // still matches "settings icon" while "Manage all history" — the
            // History step's target — is already showing on that same
            // screen). Waiting for the reactive tap-evidence check alone left
            // that sitting unacted-on for several seconds in that capture.
            if (checkLookaheadSkip(index) != null) return

            val fresh = locateOnDevice(index, step, pkg)

            if (!isRunning || currentIndex != index || currentStepPhase != StepPhase.WAITING_FOR_ACTION) return

            if (fresh == null) {
                Log.e(TAG, "revalidatePlacement: step $index's target no longer confirmable — parking dot and re-scanning.")
                OverlayManager.hideDot()
                placedResult = null
                // If this step implies scrolling/swiping, the arrow should
                // reappear now that we're back to searching — it must
                // persist until the target is confidently (re-)found, not
                // just for its original brief window.
                impliedScrollDirection(step)?.let { OverlayManager.showArrow(it) }
                currentStepPhase = StepPhase.LOCATING
                val service = WayloGuidanceService.instance ?: return
                locateStep(service, index, step, pkg, shortLabel(step.instruction))
                return
            }

            val placed = placedResult
            val movedFar = placed == null ||
                kotlin.math.abs(fresh.x - placed.x) > MOVED_DISTANCE_PX ||
                kotlin.math.abs(fresh.y - placed.y) > MOVED_DISTANCE_PX
            if (movedFar) {
                Log.e(TAG, "revalidatePlacement: step $index's best target moved to (${fresh.x},${fresh.y}) — moving dot.")
                OverlayManager.showDotAtResult(fresh, shortLabel(step.instruction))
                placedResult = fresh
            }
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
                    step,
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
                // about to replace stepJob entirely. Not tied to stepJob, so
                // guard with the generation token (see taskGeneration's doc)
                // in case a newer session starts before this fires.
                val myGeneration = taskGeneration
                scope.launch {
                    delay(1500)
                    if (taskGeneration != myGeneration) return@launch
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
        lastKnownForegroundPackage = pkg
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
        lastKnownForegroundPackage = pkg
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

                val targetGone = stillThere == null || !stillThere.isConfident()
                val nextIsUp = nextAppeared != null && nextAppeared.isConfident()

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
        val myGeneration = taskGeneration
        scope.launch {
            val now = SystemClock.elapsedRealtime()
            val sinceLastAdvance = now - lastAdvanceAt
            if (sinceLastAdvance < MIN_ADVANCE_INTERVAL_MS) {
                delay(MIN_ADVANCE_INTERVAL_MS - sinceLastAdvance)
            }
            lastAdvanceAt = SystemClock.elapsedRealtime()
            delay(SETTLE_DELAY_MS) // let the new screen settle before scanning for the next target
            // A brand-new session may have started (taskGeneration bumped)
            // while this was in flight — this scope isn't tied to stepJob
            // (see taskGeneration's doc), so it isn't auto-cancelled by that.
            if (taskGeneration != myGeneration) return@launch
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

    private val SCROLL_GESTURE_WORDS = Regex("\\b(scroll|swipe)\\b", RegexOption.IGNORE_CASE)
    private val SCROLL_DOWN_WORD = Regex("\\bdown\\b", RegexOption.IGNORE_CASE)
    private val SCROLL_UP_WORD = Regex("\\bup\\b", RegexOption.IGNORE_CASE)

    /**
     * Whether [step]'s instruction or fallbackHint implies the user needs to
     * scroll/swipe to reveal the target (e.g. "Swipe up from the bottom of
     * the screen to see all your apps"), and if so, which direction the
     * arrow overlay should point. Returns null for steps with no such hint —
     * the large majority, which get no arrow at all.
     *
     * `internal` (not `private`) so this pure, Android-free piece of logic is
     * directly unit-testable, same rationale as ElementFinder's score*
     * functions — everything else in this object is entangled with live
     * Android singletons (AccessibilityService/WindowManager/TTS) and isn't
     * practically testable in a plain JVM test.
     */
    internal fun impliedScrollDirection(step: Step): ArrowView.Direction? {
        val text = "${step.instruction} ${step.fallbackHint.orEmpty()}"
        if (!SCROLL_GESTURE_WORDS.containsMatchIn(text)) return null
        return when {
            SCROLL_DOWN_WORD.containsMatchIn(text) -> ArrowView.Direction.DOWN
            SCROLL_UP_WORD.containsMatchIn(text) -> ArrowView.Direction.UP
            else -> null
        }
    }

    private val IMAGE_ONLY_TYPES = setOf("ICON_BUTTON", "IMAGE")
    private val IMAGE_ONLY_VISUAL_WORDS = Regex("\\b(picture|photo|avatar|image|thumbnail)\\b", RegexOption.IGNORE_CASE)

    /**
     * Whether [step]'s target is likely an image-only element (e.g. a round
     * profile picture) with no text/contentDescription for the tree/OCR
     * layers to ever match confidently — used to shrink the patient window
     * before escalating to partial-match/YOLO/vision (see
     * [IMAGE_ONLY_LOCATE_TIMEOUT_MS]) rather than waiting the full
     * [LOCATE_TIMEOUT_MS]. `internal` for the same unit-testability reason as
     * [impliedScrollDirection].
     */
    internal fun looksLikeImageOnlyTarget(step: Step): Boolean {
        val type = step.elementType?.uppercase()?.trim()
        if (type !in IMAGE_ONLY_TYPES) return false
        return IMAGE_ONLY_VISUAL_WORDS.containsMatchIn(step.visualDescription.orEmpty())
    }

    /**
     * Whether the last known foreground app matches what step [index]
     * expects: any launcher package for step 0 (we're meant to be on the
     * home screen looking for the app icon), or [currentAppPackage] for
     * every later step. Fails open (returns true) when we have no signal
     * yet ([lastKnownForegroundPackage] null) or no known expected package
     * for this plan (older/cached plans) — this is a guard against a KNOWN
     * mismatch, not a hard requirement we can always verify.
     */
    private fun isInExpectedApp(index: Int): Boolean =
        isInExpectedApp(index, lastKnownForegroundPackage, currentAppPackage)

    /**
     * Pure core of [isInExpectedApp] — takes the foreground/expected package
     * as parameters instead of reading the mutable fields directly, so it's
     * unit-testable without touching this object's live-singleton-entangled
     * state, same rationale as [impliedScrollDirection]/
     * [looksLikeImageOnlyTarget]. `internal` for that reason.
     */
    internal fun isInExpectedApp(index: Int, foregroundPackage: String?, expectedAppPackage: String?): Boolean {
        val fg = foregroundPackage ?: return true
        return if (index == 0) {
            ElementFinder.isLauncherPackage(fg)
        } else {
            expectedAppPackage == null || fg == expectedAppPackage
        }
    }

    /** Hide any overlay and say the wrong-app nudge once per excursion (see [hasAnnouncedWrongApp]). */
    private fun handleWrongApp() {
        OverlayManager.hideDot()
        OverlayManager.hideArrow()
        if (!hasAnnouncedWrongApp) {
            hasAnnouncedWrongApp = true
            Log.e(TAG, "handleWrongApp: foreground=$lastKnownForegroundPackage, expected=$currentAppPackage — nudging back.")
            WayloGuidanceService.instance?.speaker?.speak("This isn't the right place — please press the back button to go back.")
        }
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
        if (!isRunning) return // idempotent — guards a stale continuation racing a genuine completion
        stepJob?.cancel()
        stepJob = null
        currentStepScope = null
        currentStepPhase = null
        OverlayManager.hideDot()
        OverlayManager.hideArrow()
        WayloGuidanceService.instance?.speaker?.speak("All done! Task complete.")
        isRunning = false
        Log.e(TAG, "Task complete: '$currentTask'")
    }

    fun getCurrentStep(): Step? = steps.getOrNull(currentIndex)

    fun isActive(): Boolean = isRunning

    /** Current guidance session id — tags /failure reports (corrections, success pairs) so they group with the run they came from. */
    fun getSessionId(): String = sessionId

    /** 1-based step number matching the backend's own stepNumber field, or null if no step is active. */
    fun getCurrentStepNumber(): Int? = if (isRunning) currentIndex + 1 else null

    /** Best-effort "what's actually foreground right now", for correction-flow/failure-report payloads. */
    fun getLastKnownForegroundPackage(): String? = lastKnownForegroundPackage

    /** The task/plan's own target app package (enriched /plan response), for correction-flow/failure-report payloads. */
    fun getCurrentAppPackage(): String? = currentAppPackage

    /** The user's original task request (e.g. "how to find youtube history"), for correction-flow/failure-report payloads. */
    fun getCurrentTaskDescription(): String? = currentTask.takeIf { it.isNotBlank() }
}
