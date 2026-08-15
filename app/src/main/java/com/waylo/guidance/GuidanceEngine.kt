package com.waylo.guidance

import com.waylo.diagnostics.RunReport
import com.waylo.diagnostics.WayloVerify

import android.os.SystemClock
import android.util.Log
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.Toast
import com.waylo.accessibility.ElementFinder
import com.waylo.accessibility.WayloAccessibilityService
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

    /** Human-readable app name from the enriched /plan response (e.g. "YouTube"), used by [speakCantReachTarget]'s "Please open X" message. Null for older/cached plans or demo tasks. */
    private var currentAppName: String? = null

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

    /**
     * BUG-B fix: elapsedRealtime of the last spoken "target not found"
     * nudge ([speakTargetDescription]'s `"Look for..."` path /
     * [speakCantReachTarget]'s "Please open..." path) for the CURRENT step,
     * or 0L if none has been spoken yet this step. Throttles that speech to
     * at most once every [PATIENCE_MS] (see [notFoundNudgeAllowed]) — before
     * this fix it re-spoke on every patient-window escalation, as often as
     * every [IMAGE_ONLY_LOCATE_TIMEOUT_MS] (6s) for image-only targets.
     * Reset to 0L per-step in [executeStep].
     */
    private var lastNotFoundNudgeAt = 0L

    /**
     * Step-1 (app-open) empirical escalation ladder position. 0 = only the
     * gentle "Open [App]" spoken so far; each expired patience window with the
     * app still not open advances it — see [speakAppOpenEscalation], which
     * picks its next phrase from what the launcher actually did (drawer opened
     * or not) rather than a fixed script. Reset per step in [executeStep].
     */
    private var appOpenEscalationLevel = 0

    /** Guards against overlapping async tap-verification lookups from a burst of content-change events. */
    private var tapEvidenceCheckInFlight = false

    /**
     * The package name from the most recent TYPE_WINDOW_STATE_CHANGED/
     * TYPE_WINDOW_CONTENT_CHANGED event — i.e. our best signal for "what's
     * actually in the foreground right now". Updated unconditionally
     * (before the isRunning/etc. guards) in [onWindowStateChanged]/
     * [onContentChanged] so it's fresh the moment guidance needs it, and
     * persists across steps (this is a continuous signal, not per-step
     * state — only [wrongAppStreak] resets per step).
     */
    private var lastKnownForegroundPackage: String? = null

    /**
     * BUG-2/BUG-3 fix: best-effort "an IME/keyboard is probably visible right
     * now" signal. True the moment a [isImePackage] event fires (even though
     * that same event is otherwise ignored for [lastKnownForegroundPackage]
     * purposes, see [isTransientForegroundPackage]); false again the moment
     * any trusted, non-transient app package event fires. There is no
     * accessibility-window-type check anywhere in this app (no
     * [android.view.accessibility.AccessibilityWindowInfo] usage) — this is a
     * package-name heuristic only, same spirit as [isTransientForegroundPackage],
     * so it can occasionally miss real IME visibility or guess wrong. That's
     * an acceptable risk here: it only gates SPEECH/mic-prompt suppression
     * (see [speakTargetDescription], [updateMicButtonVisibility],
     * [shouldSuppressCorrectionPrompt]), never a placement-safety decision —
     * a false negative just means occasionally still talking over the
     * keyboard, not a wrong dot placement.
     */
    private var imeLikelyVisible = false

    /**
     * Consecutive [isInExpectedApp] misses seen back-to-back in [locateStep]'s
     * poll loop — diagnostic only (feeds the `WRONG_LOCATION_SUPPRESSED` log's
     * `confirmedScans` field). The app never speaks anything about being on
     * the wrong screen (that phrase was removed entirely — see
     * [locateStep]'s wrong-app branch); this purely helps a future capture
     * show whether a miss was a one-off blip or a sustained condition. Reset
     * per-step in [executeStep], and back to 0 the moment a check passes.
     */
    private var wrongAppStreak = 0

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

    /**
     * Two uses: (1) if the target is found but the user hasn't acted in this
     * long, repeat the instruction once ([schedulePatienceCheck]); (2) the
     * minimum gap between spoken "target not found" nudges while still
     * searching ([notFoundNudgeAllowed]) — reused rather than a second
     * near-duplicate constant, per BUG-B's fix ("use the existing nudge
     * timer").
     */
    private const val PATIENCE_MS = 15_000L

    /** Safety re-scan cadence while locating, in case a content-change event never arrives — the outer bound [waitForRescanTrigger] falls back to when neither an accessibility event nor [PERIODIC_RESCAN_MS] wakes it first. */
    private const val RESCAN_POLL_MS = 1500L

    /**
     * BUG-A fix: [periodicRescan] re-runs the find pipeline on this cadence
     * while a step is LOCATING, independent of accessibility events — a real
     * capture showed a target already visible on screen not get found until
     * the user manually caused a new TYPE_WINDOW_CONTENT_CHANGED event (e.g.
     * a scroll), meaning the existing event-driven trigger plus
     * [RESCAN_POLL_MS]'s 1.5s fallback wasn't responsive enough. Tighter than
     * [RESCAN_POLL_MS] deliberately — this is the primary responsiveness
     * mechanism now; 900ms sits in the requested 800ms-1s band: fast enough
     * to feel immediate to a user watching the screen, not so fast it
     * meaningfully increases the tree-walk battery/CPU cost of a mechanism
     * that already polls every 1.5s at minimum.
     */
    private const val PERIODIC_RESCAN_MS = 900L

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

    /**
     * A lookahead skip ABANDONS the intermediate steps between here and the
     * jumped-to step, so it must clear a MUCH higher bar than the generic
     * confidence floor (MIN_CONFIDENT_SCORE=35) that a normal placement uses.
     * Device captures show real "you're already ahead" matches score 145+,
     * while false jumps — e.g. a contact's round profile photo in the chat
     * list matching a later "gallery photo thumbnail" step — score ~50. This
     * threshold cleanly rejects those. When in doubt the loop simply does NOT
     * skip; the user can always jump forward themselves with the red Next
     * button, so a missed auto-skip is cheap while a wrong one is confusing.
     */
    private const val LOOKAHEAD_SKIP_MIN_SCORE = 80

    /**
     * Master kill-switch for automatic step-skipping. Turned OFF: device
     * testing showed it causes more harm than help now that the red Next
     * button exists — it produced false jumps (a profile photo matching a
     * later "gallery photo" step; a home-screen Phone icon matching a later
     * "about phone" step) and, worst, a DOUBLE advance when the user pressed
     * Next and the freshly-started step immediately skipped itself again.
     * Forward movement is now driven only by real evidence (the user taps the
     * boxed target / the next step's target genuinely appears) or the user
     * pressing Next. Flip back to true to re-enable the lookahead behaviour.
     */
    private const val LOOKAHEAD_SKIP_ENABLED = false

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
    fun start(task: String, stepList: List<Step>, appPackage: String? = null, appName: String? = null) {
        if (stepList.isEmpty()) {
            Log.e(TAG, "start() called with no steps.")
            return
        }
        currentTask = task
        steps = stepList
        currentIndex = 0
        currentAppPackage = appPackage
        currentAppName = appName
        isRunning = true
        lastAdvanceAt = 0L
        sessionId = java.util.UUID.randomUUID().toString()
        taskGeneration++ // invalidates any stale advanceFrom/checkLookaheadSkip/vision-recovery continuation still pending from a previous session
        Log.e(TAG, "Guidance started: '$task' with ${stepList.size} steps. appPackage=$appPackage")
        // Open the per-run debug report (crash-safe JSONL + latest.md digest in
        // the app's files dir). No-ops for report I/O never affect guidance.
        WayloGuidanceService.instance?.let { svc ->
            RunReport.startRun(svc, sessionId, task, stepList, appPackage, appName)
        }
        appOpenNextPromptSpoken = false
        OverlayManager.showNextButton { manualAdvance() }
        executeStep(0)
        announceNextButtonOnce()
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
                    start(task, plan.steps, plan.appPackage, plan.appName) // delegate to the existing overload
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
        OverlayManager.hideNextButton()
        WayloGuidanceService.instance?.speaker?.stop()
        Log.e(TAG, "Guidance stopped.")
        RunReport.endRun("stopped")
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
        OverlayManager.hideNextButton()
        Log.e(TAG, "Guidance paused for financial app.")
    }

    /** Called by [FinancialAppGuard] once the user has left the financial app. */
    fun resumeAfterFinancialApp() {
        if (!pausedForFinancialApp) return
        pausedForFinancialApp = false
        Log.e(TAG, "Guidance resuming after financial app.")
        if (isRunning) {
            OverlayManager.showNextButton { manualAdvance() }
            executeStep(currentIndex)
        }
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
        WayloVerify.d("STEP_START | stepIndex=$index | elementType=${step.elementType ?: "null"} | " +
                "instruction=${step.instruction.take(60)} | findDescription=${step.findDescription.take(80)}"
        )

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
        wrongAppStreak = 0
        lastNotFoundNudgeAt = 0L
        appOpenEscalationLevel = 0
        advancing = false

        // BUG 3: keep the mic overlay off the keyboard the moment we know
        // this step is TEXT_INPUT (or IME is already up from a previous
        // signal) — see updateMicButtonVisibility()'s doc.
        updateMicButtonVisibility()

        // stepJob?.cancel() below stops any PREVIOUS step's locateStep()/
        // periodicRescan() coroutines before either is (re-)launched for
        // this step — so there is never more than one periodic-rescan timer
        // running at once (BUG A's "not stack multiple timers" requirement).
        stepJob?.cancel()
        val job = Job(scope.coroutineContext[Job])
        stepJob = job
        val stepScope = CoroutineScope(scope.coroutineContext + job)
        currentStepScope = stepScope

        if (isNavigationStep(step)) {
            // Pure navigation (opening an app / searching for it via the
            // launcher): no element on THIS screen to point a dot at, so no
            // L0-L3 search is attempted at all. currentVerification is
            // already Verification.AppLaunch (see verificationFor) — the
            // step advances the moment onWindowStateChanged sees the
            // expected package. Element-finding only begins on the NEXT
            // step, once we've actually landed in the target app.
            Log.e(TAG, "executeStep: step $index is pure navigation — skipping element grounding.")
            currentStepPhase = StepPhase.WAITING_FOR_ACTION
            dotShownAt = SystemClock.elapsedRealtime()
            schedulePatienceCheck(index)
            return
        }

        val pkg = currentAppPackage ?: guessPackage(currentTask, step.findDescription)
        stepScope.launch {
            val service = WayloGuidanceService.instance
            if (service == null) {
                Log.e(TAG, "No service context — cannot run guidance.")
                return@launch
            }
            locateStep(service, index, step, pkg, spoken)
        }
        // BUG A: an independent, tighter-cadence rescan running alongside
        // locateStep() — see periodicRescan()'s doc for why and how it
        // avoids racing locateStep() for who gets to place the dot.
        stepScope.launch { periodicRescan(index, step, pkg) }
    }

    /**
     * Decide how step [index]'s completion will be detected:
     *  - TEXT_INPUT -> [Verification.TextInput] (target's text becomes non-empty).
     *  - APP_ICON, NAVIGATION (see [isNavigationStep]), or step 1 from the home
     *    screen, or (for legacy plans with no elementType) an instruction that
     *    reads like "Open/Launch/Start ..." -> [Verification.AppLaunch]
     *    (window-state change into the expected app).
     *  - Everything else (ICON_BUTTON/BUTTON/LIST_ITEM, and any other/unknown
     *    type) -> [Verification.TapInApp] (click or content-change evidence).
     */
    private fun verificationFor(index: Int, step: Step): Verification {
        val type = step.elementType?.uppercase()?.trim()
        val looksLikeAppOpen = type == "APP_ICON" || type == "NAVIGATION" ||
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
     * Whether [step] is a pure-navigation action (opening an app, or
     * searching for it via the launcher's app-drawer search) with nothing
     * concrete on screen to point a dot at — e.g. "Swipe up from the home
     * screen and type Instagram to search for it." These steps skip element
     * grounding (L0-L3) entirely; see [executeStep]. Element-finding resumes
     * on the NEXT step, once [Verification.AppLaunch] confirms we've landed
     * in the target app. `internal` for the same unit-testability reason as
     * [impliedScrollDirection]/[looksLikeImageOnlyTarget].
     */
    internal fun isNavigationStep(step: Step): Boolean =
        step.elementType?.uppercase()?.trim() == "NAVIGATION"

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
            // PRIORITY FIX: a confident on-screen match for THIS step's own
            // target is stronger evidence of "right place" than the
            // foreground-package reading, which is updated unconditionally
            // on every accessibility event and can be transiently wrong
            // (a screen-recorder toggle, system dialog, or IME briefly
            // reporting com.android.systemui/com.oplus.screenrecorder/etc.
            // instead of the real app — see isTransientForegroundPackage).
            // So: ALWAYS attempt to locate the target first, regardless of
            // isInExpectedApp() — only fall back to the wrong-app guard as a
            // FALLBACK signal, once no confident match was found this scan.
            val result = locateOnDevice(index, step, pkg)
            if (result != null) {
                wrongAppStreak = 0
                if (isPlacementOverridingPackageMismatch(index, lastKnownForegroundPackage, currentAppPackage)) {
                    WayloVerify.d("PLACEMENT_OVERRIDES_PACKAGE | stepIndex=$index | score=${result.confidence} | " +
                            "currentPackage=${lastKnownForegroundPackage ?: "null"} | expectedPackage=${currentAppPackage ?: "null"}"
                    )
                }
                onTargetLocated(index, step, spoken, result)
                return
            }

            // No confident match this scan — NOW the package reading
            // matters, purely as a fallback signal (never an override of a
            // real hit, since a hit above always returns before here). Wait
            // here until a window change brings them back, rather than
            // burning the patient window on a screen we already know is
            // wrong.
            if (!isInExpectedApp(index)) {
                // Always safe to hide immediately — a stray match from the
                // wrong screen must never sit there, and hiding an
                // already-hidden dot/arrow is a harmless no-op.
                OverlayManager.hideDot()
                OverlayManager.hideArrow()
                wrongAppStreak++
                // The "wrong place / go back" phrase is gone permanently —
                // silence is the desired behavior while this is happening
                // (see CHANGE 1). Purely diagnostic; never spoken.
                WayloVerify.d("WRONG_LOCATION_SUPPRESSED | stepIndex=$index | confirmedScans=$wrongAppStreak")

                if (SystemClock.elapsedRealtime() >= deadline) {
                    // Regression guard: without this, a foreground-package
                    // reading that's stuck wrong (see wrongAppStreak's doc —
                    // lastKnownForegroundPackage has no settling delay) would
                    // loop in this branch silently FOREVER — it `continue`s
                    // past the identical deadline-escalation block below on
                    // every iteration, so it would never reach it. Give the
                    // user SOME actionable guidance instead of total silence,
                    // via the same one-shot-per-window mechanism as the
                    // normal not-found path below (shares `deadline`, so this
                    // and that path can't both fire for the same window).
                    // Deliberately does NOT call tryPartialMatchAcceptance/
                    // tryVisionFallback here — those search the CURRENT
                    // (confirmed wrong) screen, which is exactly what must
                    // never happen; speakCantReachTarget only reads step
                    // data, no live screen search.
                    Log.e(TAG, "locateStep: step $index still not in expected app after ${timeoutMs}ms — giving actionable guidance instead of looping silently.")
                    speakCantReachTarget(step, index)
                    deadline = SystemClock.elapsedRealtime() + timeoutMs
                }
                waitForRescanTrigger()
                continue
            }
            wrongAppStreak = 0

            // Screen-aware step skipping — unchanged scope: only reached
            // once confirmed in the expected app (this step's OWN target
            // confidence already overrides the package check above; a
            // LOOKAHEAD step's target is a different, riskier proposition —
            // searching for it against what might be a genuinely different
            // app's tree, not just a transiently-misread package, is exactly
            // what isInExpectedApp exists to prevent).
            if (checkLookaheadSkip(index) != null) return

            if (SystemClock.elapsedRealtime() >= deadline) {
                Log.e(TAG, "locateStep: on-device pipeline timed out for step $index, trying a confidence-gated partial match.")
                if (tryPartialMatchAcceptance(index, step, pkg)) return

                Log.e(TAG, "locateStep: no confident partial match either, trying vision fallback.")
                when (tryVisionFallback(service, index, step, spoken)) {
                    VisionOutcome.FOUND -> return
                    VisionOutcome.DESCRIBED -> Unit // already spoken a description of the target — keep waiting
                    VisionOutcome.MISSED -> {
                        // Never guess a dot position, and never fall back to
                        // a "wrong place / go back" phrase — describe the
                        // target (or, for an AppLaunch step, ask the user to
                        // open the app) and open a fresh patient window
                        // instead of giving up on the user.
                        Log.e(TAG, "locateStep: still not confident after ${timeoutMs}ms, giving actionable guidance instead of guessing.")
                        speakCantReachTarget(step, index)
                    }
                }
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
        if (!LOOKAHEAD_SKIP_ENABLED) return null
        if (!isRunning || currentIndex != index || pausedForFinancialApp) return null
        // NEVER skip from the app-open step: the user isn't in the app yet, so
        // an in-app later-step target that "matches" on the home screen (e.g. a
        // Phone icon matching a later "about phone" step) is always a false
        // positive. Step 0 advances only on real app-foreground or the Next
        // button. (Observed: fromStep=0 -> toStep=1 at score 130 on the home
        // screen, jumping into Settings before Settings was even open.)
        if (index == 0) return null
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
            // High-consequence action: require a STRONG match, not just the
            // generic confidence floor, or a weak look-alike (a profile photo
            // vs a "gallery photo thumbnail") can abandon needed steps.
            if (!match.isConfident() || match.score < LOOKAHEAD_SKIP_MIN_SCORE) {
                if (match.isConfident()) {
                    Log.e(TAG, "STEP_SKIP_REJECTED: step ${index + 1} -> step ${targetIndex + 1} score=${match.score} below skip floor $LOOKAHEAD_SKIP_MIN_SCORE")
                }
                continue
            }

            if (pendingSkipTargetIndex != targetIndex) {
                pendingSkipTargetIndex = targetIndex
                Log.e(
                    TAG,
                    "STEP_SKIP_PENDING: step ${index + 1} -> step ${targetIndex + 1} " +
                        "(score=${match.score}) seen once, confirming next scan before jumping."
                )
                WayloVerify.d("LOOKAHEAD_SKIP | fromStep=$index | toStep=$targetIndex | matchScore=${match.score} | confirmedScans=1"
                )
                return null
            }

            Log.e(
                TAG,
                "STEP_SKIP: step ${index + 1} ('${steps[index].findDescription}') not found this scan; " +
                    "jumping to step ${targetIndex + 1} (target='${targetStep.findDescription}', " +
                    "score=${match.score}, runnerUp=${match.runnerUpScore}); lookahead scan=[$scoreLog]"
            )
            WayloVerify.d("LOOKAHEAD_SKIP | fromStep=$index | toStep=$targetIndex | matchScore=${match.score} | confirmedScans=2"
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
     * [ElementFinder.findPartialMatch]. That still requires the full
     * confidence floor (score + runner-up gap) — this only widens WHAT is
     * searched (semantic hints instead of findDescription), never lowers the
     * bar for accepting it, so a hit here is a normal confident placement
     * with no special caveat spoken. Logged (tagged `PARTIAL_MATCH`) for the
     * same later-audit reason as [checkLookaheadSkip].
     *
     * @return true if a confident partial match was found (dot placed, phase
     * moved to WAITING_FOR_ACTION via [onTargetLocated]) — caller should stop
     * looping. False if nothing qualified — caller proceeds to vision fallback.
     */
    private fun tryPartialMatchAcceptance(index: Int, step: Step, pkg: String?): Boolean {
        if (!isRunning || currentIndex != index || pausedForFinancialApp) return false

        val targetPackageForSearch = if (index == 0) pkg else null
        val match = ElementFinder.findPartialMatch(step.alternateLabels, step.visualDescription, targetPackageForSearch, index)
            ?: return false

        Log.e(
            TAG,
            "PARTIAL_MATCH: step ${index + 1} ('${step.findDescription}') not found after the full patient window; " +
                "found a confident match via alternateLabels/visualDescription " +
                "(score=${match.score}, runnerUp=${match.runnerUpScore})."
        )
        val label = visibleLabelFor(match, step.findDescription)
        val bounds = ElementFinder.getBoundsOnScreen(match.node)
        val result = ScreenAnalysisPipeline.PipelineResult(
            x = bounds.centerX(),
            y = bounds.centerY(),
            source = "partial-match",
            confidence = match.score.toFloat(),
            label = label,
            width = bounds.width(),
            height = bounds.height()
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
                ElementFinder.findOnHomeScreen(step.findDescription, pkg, step.alternateLabels, index)
            }
            if (home != null && home.isConfident()) {
                val bounds = ElementFinder.getBoundsOnScreen(home.node)
                return ScreenAnalysisPipeline.PipelineResult(
                    x = bounds.centerX(),
                    y = bounds.centerY(),
                    source = "home-screen",
                    confidence = home.score.toFloat(),
                    label = step.findDescription,
                    width = bounds.width(),
                    height = bounds.height()
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
                step.visualDescription,
                index
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
     * BUG A fix: runs alongside [locateStep] (launched from [executeStep] on
     * the same [currentStepScope]/`stepJob`, so it starts and stops with the
     * step exactly like every other per-step coroutine — see [executeStep]'s
     * comment on why this can never stack more than one timer). On
     * [PERIODIC_RESCAN_MS], reruns [locateOnDevice] — the SAME pipeline
     * [locateStep] itself calls, so no scoring/matching logic is duplicated —
     * purely to see whether the target has become findable independent of
     * any accessibility event.
     *
     * Deliberately does NOT call [onTargetLocated] itself. [locateStep]'s own
     * loop is the single path that ever places the dot; if this coroutine
     * finds a confident result it only flips [locateRescanRequested] to wake
     * that loop early (the same flag [waitForRescanTrigger] already checks
     * every 150ms), then stops. That loop then re-locates and places the dot
     * through its own existing call, so there is exactly one caller of
     * [onTargetLocated] ever — this coroutine finding something a few
     * milliseconds before locateStep()'s own next tick cannot race it into a
     * double placement.
     *
     * Stops itself the moment the step is no longer LOCATING (found, wrong
     * app parked it back to LOCATING then found, or the step changed/ended)
     * without waiting for cancellation — see [shouldContinuePeriodicRescan].
     */
    private suspend fun periodicRescan(index: Int, step: Step, pkg: String?) {
        while (shouldContinuePeriodicRescan(isRunning, currentIndex == index, currentStepPhase == StepPhase.LOCATING)) {
            delay(PERIODIC_RESCAN_MS)
            if (!shouldContinuePeriodicRescan(isRunning, currentIndex == index, currentStepPhase == StepPhase.LOCATING)) return

            val result = locateOnDevice(index, step, pkg)
            WayloVerify.d("PERIODIC_RESCAN | stepIndex=$index | found=${result != null} | topScore=${result?.confidence ?: 0f}"
            )
            if (result != null) {
                locateRescanRequested = true
                return
            }
        }
    }

    /**
     * Pure stop-condition for [periodicRescan]'s loop, extracted so the exact
     * "start while waiting, stop once found or the step changes" contract is
     * unit-testable without the coroutine/Android entanglement — same
     * rationale as [isInExpectedApp]/[impliedScrollDirection]. `internal` for
     * that reason.
     */
    internal fun shouldContinuePeriodicRescan(isRunning: Boolean, isCurrentStep: Boolean, isLocating: Boolean): Boolean =
        isRunning && isCurrentStep && isLocating

    /**
     * The target cleared the confidence floor: show the dot and switch into
     * the WAITING_FOR_ACTION phase where the accessibility-event handlers
     * below take over verification.
     *
     * Speech policy: the step's instruction is spoken once, flushing, at the
     * start of the step in [executeStep] — that is the ONLY announcement for
     * finding/placing the target. BUG-1's fix made [speakTargetDescription]
     * always speak [Step.instruction] verbatim, which is the exact same text
     * already spoken at step start — so a previous "Tap X" re-announcement
     * queued from here would now be a byte-for-byte repeat of what was just
     * said (it used to describe the matched element using
     * findDescription/visualDescription/the element's own label, which
     * *could* differ from the instruction; once forced to instruction-only,
     * repeating it here can never add information). Removed entirely rather
     * than kept as a no-op repeat — see WAYLO_SPEECH_MIC_FIX.md. Never a
     * "the dot" reference — that narration was permanently removed. Total
     * speech per step: the instruction once, at most one gentle idle nudge
     * ([schedulePatienceCheck]), and the fallbackHint if truly stuck
     * ([speakFallbackHint]) — nothing else.
     */
    /**
     * Minimum tree-search score required to actually DRAW the box. A match
     * confident enough to search on (MIN_CONFIDENT_SCORE=35) can still be a weak
     * look-alike — a device capture showed a "model name text" step put a box on
     * the wrong element at score 45 ("drawing over wrong things"). Below this
     * floor we keep the step live (the instruction and the Next button still
     * work) but draw NO box, since a box on the wrong element is worse than
     * none. Real placements score well above this (70–185). Applies only to
     * tree sources; OCR/YOLO/vision carry their own calibrated gates.
     */
    private const val DRAW_MIN_TREE_SCORE = 60f

    private fun shouldDrawBoxFor(result: ScreenAnalysisPipeline.PipelineResult): Boolean {
        val treeSourced = result.source == "accessibility" ||
            result.source == "home-screen" || result.source == "partial-match"
        return !(treeSourced && result.confidence < DRAW_MIN_TREE_SCORE)
    }

    private fun onTargetLocated(index: Int, step: Step, spoken: String, result: ScreenAnalysisPipeline.PipelineResult) {
        if (!isRunning || currentIndex != index) return
        Log.e(TAG, "Target located for step ${index + 1}: source=${result.source} confidence=${result.confidence}")
        // The target resolved — if a scroll/swipe arrow was showing while we
        // searched, switch it out for the box on the actual target now. But a
        // weak tree match draws NO box (see shouldDrawBoxFor) rather than
        // boxing the wrong element.
        OverlayManager.hideArrow()
        val drawBox = shouldDrawBoxFor(result)
        if (drawBox) {
            OverlayManager.showDotAtResult(result, spoken)
        } else {
            OverlayManager.hideDot()
        }
        val sourceLayer = when (result.source) {
            "accessibility", "home-screen", "partial-match" -> "TREE"
            "ocr" -> "OCR"
            // FallbackHandler tags any Found() from its OCR/YOLO retry chain
            // as "vision" regardless of which of those two actually hit —
            // Gemini Vision LOCATE itself never reaches here (it only ever
            // returns Described, see VISION_CALL for the real sub-layer).
            "vision" -> "YOLO_OR_OCR_RETRY"
            else -> result.source.uppercase()
        }
        WayloVerify.d("DOT_PLACED | stepIndex=$index | x=${result.x} | y=${result.y} | sourceLayer=$sourceLayer | score=${result.confidence} | drawn=$drawBox"
        )
        // Only treat this as the placed target (for the tap-location match) when
        // we actually drew a box on it — a suppressed weak match must not let a
        // stray tap near its guessed coords count as "tapped the target".
        placedResult = if (drawBox) result else null
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

            // PRIORITY FIX (same as locateStep()): a confident element match
            // is stronger evidence of "right place" than the foreground-
            // package reading, which can be transiently wrong (screen-
            // recorder toggle, system dialog, IME). Screen-aware step
            // skipping keeps running on EVERY tick regardless of the current
            // target's status, exactly as before (see its own doc below) —
            // it and the current-target recheck right after it no longer
            // depend on isInExpectedApp passing first; the package check now
            // only applies once NEITHER produces a confident match.
            //
            // Screen-aware step skipping, deliberately WITHOUT gating on the
            // current target being absent (unlike the LOCATING-phase call in
            // locateStep()): device testing showed the dot can stay
            // confidently "confirmed" on this step's target (e.g. a screen
            // title that still matches) even after the user has already
            // moved to a screen where a LATER step's target is also directly
            // visible (e.g. YouTube's Settings screen title still matches
            // "settings icon" while "Manage all history" — the History
            // step's target — is already showing on that same screen).
            // Waiting for the reactive tap-evidence check alone left that
            // sitting unacted-on for several seconds in that capture.
            if (checkLookaheadSkip(index) != null) return

            val fresh = locateOnDevice(index, step, pkg)

            if (!isRunning || currentIndex != index || currentStepPhase != StepPhase.WAITING_FOR_ACTION) return

            if (fresh != null) {
                if (isPlacementOverridingPackageMismatch(index, lastKnownForegroundPackage, currentAppPackage)) {
                    WayloVerify.d("PLACEMENT_OVERRIDES_PACKAGE | stepIndex=$index | score=${fresh.confidence} | " +
                            "currentPackage=${lastKnownForegroundPackage ?: "null"} | expectedPackage=${currentAppPackage ?: "null"}"
                    )
                }
                val placed = placedResult
                val movedFar = placed == null ||
                    kotlin.math.abs(fresh.x - placed.x) > MOVED_DISTANCE_PX ||
                    kotlin.math.abs(fresh.y - placed.y) > MOVED_DISTANCE_PX
                if (movedFar) {
                    // Same weak-match guard as onTargetLocated: don't re-draw a
                    // box on a low-confidence tree match.
                    val drawBox = shouldDrawBoxFor(fresh)
                    Log.e(TAG, "revalidatePlacement: step $index's best target moved to (${fresh.x},${fresh.y}) — drawBox=$drawBox.")
                    WayloVerify.d("REVALIDATE | stepIndex=$index | stillValid=true | newTopScore=${fresh.confidence} | reason=moved_dot | drawn=$drawBox")
                    if (drawBox) {
                        OverlayManager.showDotAtResult(fresh, shortLabel(step.instruction))
                        placedResult = fresh
                    } else {
                        OverlayManager.hideDot()
                        placedResult = null
                    }
                } else {
                    WayloVerify.d("REVALIDATE | stepIndex=$index | stillValid=true | newTopScore=${fresh.confidence} | reason=no_change")
                }
                continue
            }

            // No confident match this tick (neither a lookahead jump nor the
            // current target) — NOW the package reading matters, purely as a
            // fallback signal. The user may have wandered into a different
            // app entirely while the dot sat waiting for a tap — the dot
            // must not stay visible in that case. Park it and drop back to
            // LOCATING, where locateStep()'s own (also now reordered) gate
            // takes over.
            if (!isInExpectedApp(index)) {
                Log.e(TAG, "revalidatePlacement: step $index — no longer in the expected app, parking dot.")
                WayloVerify.d("REVALIDATE | stepIndex=$index | stillValid=false | newTopScore=0 | reason=wrong_app")
                OverlayManager.hideDot()
                placedResult = null
                currentStepPhase = StepPhase.LOCATING
                val service = WayloGuidanceService.instance ?: return
                locateStep(service, index, step, pkg, shortLabel(step.instruction))
                return
            }

            Log.e(TAG, "revalidatePlacement: step $index's target no longer confirmable — parking dot and re-scanning.")
            WayloVerify.d("REVALIDATE | stepIndex=$index | stillValid=false | newTopScore=0 | reason=no_longer_confirmable")
            OverlayManager.hideDot()
            placedResult = null
            // If this step implies scrolling/swiping, the arrow should
            // reappear now that we're back to searching — it must persist
            // until the target is confidently (re-)found, not just for its
            // original brief window.
            impliedScrollDirection(step)?.let { OverlayManager.showArrow(it) }
            currentStepPhase = StepPhase.LOCATING
            val service = WayloGuidanceService.instance ?: return
            locateStep(service, index, step, pkg, shortLabel(step.instruction))
            return
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
                ElementFinder.findElement(step.findDescription, null, step.alternateLabels, index)
            }
            if (!isRunning || currentIndex != index || currentStepPhase != StepPhase.WAITING_FOR_ACTION) return
            val hasText = match != null && !match.node.text.isNullOrBlank()
            WayloVerify.d("ADVANCE_CHECK | stepIndex=$index | elementType=${step.elementType ?: "null"} | verified=$hasText | reason=textInput_poll_hasText=$hasText"
            )
            if (hasText) {
                Log.e(TAG, "pollTextInput: text became non-empty, advancing.")
                advanceFrom(index)
                return
            }
        }
    }

    /** Outcome of [tryVisionFallback], distinguishing "dot placed" from "described but still below the confidence floor". */
    private enum class VisionOutcome { FOUND, DESCRIBED, MISSED }

    /**
     * Layer 3 recovery: when the on-device pipeline can't find the target after
     * a full patient window, call the Gemini Vision fallback chain (also tries
     * OCR/YOLO again first). OCR/YOLO hits (real scores) place the dot;
     * Gemini Vision LOCATE never does (see [FallbackHandler.FallbackResult.Described])
     * — it only supplies a better description to speak while the caller keeps
     * re-scanning on-device. NewSteps splices recovery steps in and restarts;
     * Failed reports back so the caller can keep waiting instead of guessing
     * a position.
     */
    private suspend fun tryVisionFallback(
        service: WayloGuidanceService,
        index: Int,
        step: Step,
        spoken: String
    ): VisionOutcome {
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
                WayloVerify.d("VISION_CALL | stepIndex=$index | outcome=FOUND | descriptionReturned=${(result.updatedInstruction ?: "").take(80)}")
                VisionOutcome.FOUND
            }

            is FallbackHandler.FallbackResult.Described -> {
                Log.e(TAG, "Vision described the target but it has no on-device score yet — waiting for a confident match instead of placing the dot.")
                // BUG-1 fix: no longer speaks result.description (Gemini
                // Vision's own phrasing) — only ever the step's instruction.
                speakTargetDescription(step, stepIndex = index)
                WayloVerify.d("VISION_CALL | stepIndex=$index | outcome=DESCRIBED | descriptionReturned=${result.description.take(80)}")
                VisionOutcome.DESCRIBED
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
                WayloVerify.d("VISION_CALL | stepIndex=$index | outcome=FOUND | descriptionReturned=${result.explanation.take(80)}")
                VisionOutcome.FOUND // steps replaced — caller should stop this loop
            }

            is FallbackHandler.FallbackResult.Failed -> {
                Log.e(TAG, "Vision fallback failed: ${result.reason}")
                WayloVerify.d("VISION_CALL | stepIndex=$index | outcome=MISSED | descriptionReturned=${result.reason.take(80)}")
                VisionOutcome.MISSED
            }
        }
    }

    /**
     * BUG-1 fix: speaks step [step]'s own user-facing [Step.instruction] —
     * VERBATIM, and ONLY that field. A real capture showed
     * `SPOKE_DESCRIPTION | whichFieldUsed=findDescription` on every single
     * step: a previous version of this function built a spoken sentence
     * from [Step.findDescription]/[Step.visualDescription]/[Step.fallbackHint]
     * — matcher-only data, never meant for a human ear (`findDescription` in
     * particular is often a long, hedge-y search phrase full of
     * "or"/"maybe"/alternate-wording, written for `ElementFinder`/OCR
     * scoring, not speech). See `WAYLO_SPEECH_MIC_FIX.md` for the full root
     * cause. [targetDescriptionMessage] is the one place that decides what
     * text this speaks — kept as a separate, pure, unit-tested function
     * specifically so "always instruction, never findDescription" has a
     * direct regression test.
     *
     * Never a "the dot" reference or a "wrong place / go back" phrase —
     * both permanently removed (see this file's history).
     *
     * Suppressed entirely (never speaks, not even once) when:
     *  - [isActionStepNoRepeat] — the user is presumably mid-action
     *    (typing, swiping, already navigating an app-open step) and must
     *    never be talked over (BUG 2).
     *  - [imeLikelyVisible] — same reasoning, keyed off the IME/keyboard
     *    signal instead of the step type (BUG 2/3).
     * Otherwise throttled to at most once every [PATIENCE_MS] via
     * [notFoundNudgeAllowed] (BUG-B fix from a previous session — before
     * that fix this re-spoke on every patient-window escalation, as often as
     * every [IMAGE_ONLY_LOCATE_TIMEOUT_MS] for image-only targets).
     *
     * The app is English-only right now ([com.waylo.voice.Speaker] hardcodes
     * `Locale.ENGLISH`) — there is no existing per-language branching to
     * hook a Hindi variant into, so this speaks English like every other
     * string in the app.
     */
    private fun speakTargetDescription(step: Step, stepIndex: Int = -1) {
        if (isActionStepNoRepeat(step)) {
            WayloVerify.d("SPOKE_DESCRIPTION_SUPPRESSED | stepIndex=$stepIndex | reason=action_step_no_repeat")
            return
        }
        if (imeLikelyVisible) {
            WayloVerify.d("SPOKE_DESCRIPTION_SUPPRESSED | stepIndex=$stepIndex | reason=ime_likely_visible")
            return
        }
        if (!notFoundNudgeAllowed()) {
            WayloVerify.d("SPOKE_DESCRIPTION_SUPPRESSED | stepIndex=$stepIndex | sinceLastNudgeMs=${SystemClock.elapsedRealtime() - lastNotFoundNudgeAt}"
            )
            return
        }
        val message = targetDescriptionMessage(step)
        WayloGuidanceService.instance?.speaker?.speak(message)
        WayloVerify.d("SPOKE_DESCRIPTION | stepIndex=$stepIndex | whichFieldUsed=instruction | screenRegionUsed=false | fallbackHintUsed=false"
        )
    }

    /**
     * BUG-1 fix: the exact text [speakTargetDescription] speaks — ALWAYS
     * [Step.instruction] verbatim, never [Step.findDescription]/
     * [Step.visualDescription]/[Step.fallbackHint]. Kept as its own tiny
     * function (rather than inlined) purely so this contract has a direct
     * unit test independent of [speakTargetDescription]'s Android/singleton
     * entanglement (`WayloGuidanceService.instance`, [SystemClock]) — same
     * rationale as [isInExpectedApp]'s pure core. `internal` for that
     * testability.
     */
    internal fun targetDescriptionMessage(step: Step): String = step.instruction

    /**
     * BUG-2: whether the current step is one where the user is presumably
     * mid-action — typing ([Verification.TextInput]), opening/navigating an
     * app ([Verification.AppLaunch]: step 0, `APP_ICON`, `NAVIGATION`), or
     * the instruction implies a scroll/swipe gesture — and so must never be
     * talked over by a repeated "not found" nudge. `internal` pure core
     * takes plain booleans rather than [Verification] directly since that
     * sealed class is `private` (an `internal` function can't expose a
     * private type in its signature) — same pattern as
     * [shouldContinuePeriodicRescan] avoiding [StepPhase] for the same
     * reason.
     */
    private fun isActionStepNoRepeat(step: Step): Boolean =
        isActionStepNoRepeat(
            isTextInput = currentVerification is Verification.TextInput,
            isAppLaunch = currentVerification is Verification.AppLaunch,
            impliesScroll = impliedScrollDirection(step) != null
        )

    internal fun isActionStepNoRepeat(isTextInput: Boolean, isAppLaunch: Boolean, impliesScroll: Boolean): Boolean =
        isTextInput || isAppLaunch || impliesScroll

    /**
     * CHANGE-4 policy: when a step's target genuinely can't be reached — the
     * patient window expired with nothing found, or the screen was confirmed
     * wrong for the whole window — tell the user in plain words what to do
     * instead. Never falls back to a "wrong place / go back" phrase (deleted
     * permanently) or a dot reference (also deleted). [Verification.AppLaunch]
     * steps (opening/finding an app — step 0, APP_ICON, NAVIGATION) get
     * "Please open <app name>" when the plan's own [currentAppName] is known;
     * everything else — including an AppLaunch step on an older/cached plan
     * with no app name — falls back to the normal target description (which
     * throttles itself). BUG-B fix: this branch is throttled the same way
     * via [notFoundNudgeAllowed], for the same reason.
     */
    private fun speakCantReachTarget(step: Step, index: Int) {
        val appName = currentAppName
        if (currentVerification is Verification.AppLaunch && !appName.isNullOrBlank()) {
            if (!notFoundNudgeAllowed()) {
                WayloVerify.d("SPOKE_DESCRIPTION_SUPPRESSED | stepIndex=$index | sinceLastNudgeMs=${SystemClock.elapsedRealtime() - lastNotFoundNudgeAt}"
                )
                return
            }
            // Step 1 (opening the app from the launcher): drive the launcher-
            // aware, outcome-driven ladder instead of just repeating "Please
            // open X" — the gesture the drawer needs varies by launcher.
            if (index == 0) {
                speakAppOpenEscalation(index)
                return
            }
            WayloGuidanceService.instance?.speaker?.speak("Please open $appName.")
            WayloVerify.d("SPOKE_DESCRIPTION | stepIndex=$index | whichFieldUsed=appName | screenRegionUsed=false | fallbackHintUsed=false | verb=PleaseOpen | queued=false"
            )
        } else {
            speakTargetDescription(step, stepIndex = index)
        }
    }

    /**
     * Empirically detect whether the launcher's app drawer (with its search
     * bar) is currently open — the run-time signal the app-open ladder uses to
     * decide whether the gesture it just suggested actually worked. A launcher-
     * package search field (an EditText, or a node labelled "search") is the
     * strong signal; a dense grid of launcher icon nodes is a weak secondary.
     */
    private fun isAppDrawerLikelyOpen(): Boolean {
        val nodes = WayloAccessibilityService.instance?.getAllNodes() ?: return false
        var iconish = 0
        for (n in nodes) {
            val pkg = n.packageName?.toString() ?: continue
            if (!ElementFinder.isLauncherPackage(pkg)) continue
            val cls = n.className?.toString() ?: ""
            val label = "${n.text ?: ""} ${n.contentDescription ?: ""}".lowercase()
            if (cls.contains("EditText", ignoreCase = true) || label.contains("search")) return true
            if (cls.contains("IconView") || cls.contains("BubbleTextView")) iconish++
        }
        return iconish >= 16
    }

    /**
     * Step-1 app-open escalation, driven by what the launcher actually does
     * (runtime detection was chosen over a static per-launcher gesture map).
     * Called once per expired patience window while the app still hasn't opened
     * and its icon isn't findable on screen. Each call:
     *  - if the app drawer is now open → guide the drawer SEARCH (works on
     *    every launcher regardless of the gesture that opened it);
     *  - else advance a gesture ladder: first the near-universal swipe-up, and
     *    only if that DIDN'T open the drawer, suggest a sideways swipe instead
     *    (left, then right) — reacting to the observed outcome rather than
     *    guessing the launcher's gesture up front.
     *
     * The plain-words icon dot is still placed by the normal locate loop the
     * instant the icon becomes visible (home screen OR a drawer search result);
     * this only supplies the spoken guidance while it isn't.
     */
    private fun speakAppOpenEscalation(index: Int) {
        val speaker = WayloGuidanceService.instance?.speaker ?: return
        val appName = currentAppName ?: "the app"

        if (isAppDrawerLikelyOpen()) {
            speaker.speak("Now type $appName in the search bar at the top, then tap it.")
            WayloVerify.d("APP_OPEN_ESCALATION | stepIndex=$index | level=$appOpenEscalationLevel | drawerOpen=true | action=search_prompt")
            return
        }

        val phrase = when (appOpenEscalationLevel) {
            0 -> "Swipe up from the bottom of the screen to see all your apps."
            1 -> "That didn't open your apps. Try swiping left across the screen instead."
            2 -> "Still not there? Try swiping right across the screen instead."
            else -> "Please open $appName on your phone."
        }
        speaker.speak(phrase)
        WayloVerify.d("APP_OPEN_ESCALATION | stepIndex=$index | level=$appOpenEscalationLevel | drawerOpen=false | action=gesture")
        appOpenEscalationLevel++
    }

    /**
     * BUG-B fix: stateful throttle gate for "target not found" nudges (see
     * [lastNotFoundNudgeAt]'s doc) — returns true (and records `now` as the
     * new last-spoken time) at most once every [PATIENCE_MS], false
     * otherwise. Thin wrapper around the pure [shouldAllowNotFoundNudge] so
     * the actual interval math is unit-testable without touching
     * [SystemClock]/mutable state directly, same rationale as
     * [isInExpectedApp]'s pure core.
     */
    private fun notFoundNudgeAllowed(): Boolean {
        val now = SystemClock.elapsedRealtime()
        if (!shouldAllowNotFoundNudge(now, lastNotFoundNudgeAt, PATIENCE_MS)) return false
        lastNotFoundNudgeAt = now
        return true
    }

    /**
     * Pure core of [notFoundNudgeAllowed]. `internal` for unit-testability,
     * same rationale as [isInExpectedApp]/[impliedScrollDirection].
     */
    internal fun shouldAllowNotFoundNudge(nowMs: Long, lastNudgeAtMs: Long, minIntervalMs: Long): Boolean =
        nowMs - lastNudgeAtMs >= minIntervalMs

    /**
     * Called by the accessibility service on TYPE_WINDOW_STATE_CHANGED. Only
     * [Verification.AppLaunch] steps advance on this signal — verified against
     * the expected package (or, for step 1, simply leaving the launcher).
     * Also nudges the locate loop to retry immediately, since a window change
     * may have just revealed the current step's target.
     */
    fun onWindowStateChanged(pkg: String) {
        // FIX item 3: a transient system overlay briefly taking the
        // foreground (screen recorder toggle, notification shade, a
        // permission dialog, the IME popping up) is not "the user left the
        // app" — never let it corrupt lastKnownForegroundPackage, which is
        // exactly what fed the false wrong-app blocks in the reported run.
        if (isTransientForegroundPackage(pkg)) {
            if (isImePackage(pkg)) imeLikelyVisible = true
            WayloVerify.d("TRANSIENT_PACKAGE_IGNORED | source=onWindowStateChanged | package=$pkg | " +
                    "keptForeground=${lastKnownForegroundPackage ?: "null"}"
            )
            updateMicButtonVisibility()
            return
        }
        lastKnownForegroundPackage = pkg
        imeLikelyVisible = false
        updateMicButtonVisibility()
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
        val step = steps.getOrNull(currentIndex)
        WayloVerify.d("ADVANCE_CHECK | stepIndex=$currentIndex | elementType=${step?.elementType ?: "null"} | verified=$matched | " +
                "reason=appLaunch_pkg=${pkg}_expected=${verification.expectedPackage ?: "null"}_fromLauncherOnly=${verification.fromLauncherOnly}"
        )
        if (!matched) {
            Log.e(TAG, "onWindowStateChanged($pkg): doesn't match expected app (${verification.expectedPackage}).")
            WayloVerify.d("WRONG_LOCATION | stepIndex=$currentIndex | currentPackage=$pkg | " +
                    "expectedPackage=${verification.expectedPackage ?: "null"} | whichCheckFailed=appLaunchVerification | " +
                    "compared=(current=$pkg vs expected=${verification.expectedPackage} fromLauncherOnly=${verification.fromLauncherOnly})"
            )
            return
        }

        // App-open policy (user preference): the app is open, but we do NOT
        // auto-advance — the user stays in control and moves on with the red
        // Next button. Prompt them once that the app is open and Next is next.
        Log.e(TAG, "onWindowStateChanged($pkg): app opened — waiting for Next (manual app-open advance).")
        WayloVerify.d("APP_OPENED | stepIndex=$currentIndex | package=$pkg | policy=wait_for_next")
        promptPressNextAfterOpenOnce()
    }

    /** Whether the "app is open, press Next" prompt has been spoken for the current app-open step. Reset per task in [start]. */
    private var appOpenNextPromptSpoken = false

    private fun promptPressNextAfterOpenOnce() {
        if (appOpenNextPromptSpoken) return
        appOpenNextPromptSpoken = true
        val appName = currentAppName ?: "The app"
        WayloGuidanceService.instance?.speaker?.speak("$appName is open. Now press the red Next button to continue.")
    }

    /**
     * Called by the accessibility service on TYPE_WINDOW_CONTENT_CHANGED.
     * Feeds the tap-in-app verification check and nudges the locate loop.
     */
    fun onContentChanged(pkg: String) {
        // FIX item 3 — see onWindowStateChanged's identical guard.
        if (isTransientForegroundPackage(pkg)) {
            if (isImePackage(pkg)) imeLikelyVisible = true
            WayloVerify.d("TRANSIENT_PACKAGE_IGNORED | source=onContentChanged | package=$pkg | " +
                    "keptForeground=${lastKnownForegroundPackage ?: "null"}"
            )
            updateMicButtonVisibility()
            return
        }
        lastKnownForegroundPackage = pkg
        imeLikelyVisible = false
        updateMicButtonVisibility()
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
            // Location match: the user clicked a node covering the exact spot we
            // highlighted. This is the strongest "they tapped what we pointed
            // at" signal, and unlike text scoring it survives controls whose
            // label doesn't match findDescription (e.g. a play button whose
            // contentDescription is just "Play").
            val placed = placedResult
            val clickedOnPlacedTarget = placed != null &&
                ElementFinder.getBoundsOnScreen(clickedNode).contains(placed.x, placed.y)
            if (score >= CLICK_MATCH_FLOOR || clickedOnPlacedTarget) {
                val why = if (score >= CLICK_MATCH_FLOOR) "clickedNodeMatch_score=$score" else "clickedPlacedTarget"
                Log.e(TAG, "checkTapInAppEvidence: click confirmed ($why), advancing.")
                WayloVerify.d("ADVANCE_CHECK | stepIndex=$index | elementType=${step.elementType ?: "null"} | verified=true | reason=$why"
                )
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
                    ElementFinder.findElement(step.findDescription, null, step.alternateLabels, index)
                }
                val nextStep = steps.getOrNull(index + 1)
                val nextAppeared = nextStep?.let { next ->
                    withContext(Dispatchers.IO) {
                        ElementFinder.findElement(next.findDescription, null, next.alternateLabels, index + 1)
                    }
                }
                if (currentIndex != index || currentStepPhase != StepPhase.WAITING_FOR_ACTION) return@launchInStep

                val targetGone = stillThere == null || !stillThere.isConfident()
                val nextIsUp = nextAppeared != null && nextAppeared.isConfident()

                when {
                    nextIsUp || (targetGone && viaClick) -> {
                        val reason = if (nextIsUp) "next target appeared" else "target gone + click"
                        Log.e(TAG, "checkTapInAppEvidence: confirmed ($reason).")
                        WayloVerify.d("ADVANCE_CHECK | stepIndex=$index | elementType=${step.elementType ?: "null"} | verified=true | reason=$reason"
                        )
                        advanceFrom(index)
                    }
                    targetGone -> {
                        uncertainChecks++
                        Log.e(TAG, "checkTapInAppEvidence: ambiguous (#$uncertainChecks) for step $index.")
                        WayloVerify.d("ADVANCE_CHECK | stepIndex=$index | elementType=${step.elementType ?: "null"} | verified=false | reason=ambiguous_targetGone_uncertainChecks=$uncertainChecks"
                        )
                        if (uncertainChecks >= UNCERTAIN_CHECK_LIMIT) {
                            uncertainChecks = 0
                            // Do NOT auto-complete on "target gone" — target
                            // absence is ambiguous (the user finished AND acted,
                            // OR they simply never reached the screen). A prior
                            // version completed the LAST step this way and fired
                            // a false "task complete" on a look-step whose target
                            // was never found. The last step now completes only
                            // on a real tap of the boxed control (clickedPlaced-
                            // Target above) or the user pressing Next. Just
                            // re-offer the hint here.
                            speakFallbackHint(step)
                        }
                    }
                    else -> {
                        // target still clearly present — nothing changed, keep waiting.
                        WayloVerify.d("ADVANCE_CHECK | stepIndex=$index | elementType=${step.elementType ?: "null"} | verified=false | reason=target_still_present"
                        )
                    }
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
            WayloVerify.d("ADVANCE_CHECK | stepIndex=$index | elementType=${step.elementType ?: "null"} | verified=true | reason=textChanged_directNode"
            )
            advanceFrom(index)
            return
        }

        // The event may have fired on a sibling/wrapper rather than the exact
        // node ElementFinder would pick — re-resolve from the live tree. No
        // targetPackage: we're always already inside the target app here.
        launchInStep {
            val match = withContext(Dispatchers.IO) {
                ElementFinder.findElement(step.findDescription, null, step.alternateLabels, index)
            }
            if (currentIndex == index && currentStepPhase == StepPhase.WAITING_FOR_ACTION &&
                match != null && !match.node.text.isNullOrBlank()
            ) {
                Log.e(TAG, "onTextChanged: re-resolved target now has text, advancing.")
                WayloVerify.d("ADVANCE_CHECK | stepIndex=$index | elementType=${step.elementType ?: "null"} | verified=true | reason=textChanged_reResolved"
                )
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
        // Log BOTH the raw 0-based array index and the 1-based display number
        // for each of the two steps involved, spelled out explicitly — a
        // previous version of this line ("advanceFrom($index): verified,
        // advancing to step ${index + 2}") was misread from a real capture as
        // "step 3 got skipped" when index was 2, because it printed a raw
        // 0-based index right next to a 1-based number with no labels. It
        // wasn't: executeStep(index + 1) below always advances the array by
        // exactly one position (see stepDisplayNumber's doc and
        // GuidanceEngineStepNumberingTest) — there was no skip, only an
        // ambiguous log line.
        Log.e(
            TAG,
            "advanceFrom: step ${stepDisplayNumber(index)} (array index $index) verified, " +
                "advancing to step ${stepDisplayNumber(index + 1)} (array index ${index + 1})."
        )
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

    /**
     * 1-based, human-readable step number for 0-based array position
     * [arrayIndex] — matches the numbering convention used by every other
     * step-related log line in this file (STEP_SKIP, STEP_START, etc.:
     * `${index + 1}` for "this index's own 1-based number"). Absent a
     * backend plan gap, this also matches the plan's own `stepNumber`/
     * [Step.index] field. `internal` for unit-testability, same rationale as
     * [isInExpectedApp]/[impliedScrollDirection].
     */
    internal fun stepDisplayNumber(arrayIndex: Int): Int = arrayIndex + 1

    /** Launch [block] scoped to the current step's job, so stop/pause/advance cancel it automatically. */
    private fun launchInStep(block: suspend CoroutineScope.() -> Unit): Job? =
        currentStepScope?.launch(block = block)

    /** Speak the instruction again together with the backend's fallbackHint, without advancing. */
    private fun speakFallbackHint(step: Step) {
        // Step 1 is the app-open step: per product direction we don't nag with
        // "swipe up / search" hints — the user opens the app themselves and we
        // advance on app-foreground or the red Next button. Skip the fallback.
        if (currentIndex == 0) return
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
     * User pressed the on-screen red Next button — force-advance the current
     * step regardless of auto-verification. The reliable manual override for
     * steps where auto-advance can't tell the user acted (video players with no
     * click event, the app-open step, etc.). Goes through the same
     * rate-limited [advanceFrom] path as any other advance signal.
     */
    fun manualAdvance() {
        if (!isRunning) return
        WayloVerify.d("MANUAL_ADVANCE | stepIndex=$currentIndex")
        Log.e(TAG, "manualAdvance: user pressed Next on step ${currentIndex + 1}")
        advanceFrom(currentIndex)
    }

    /** Whether the one-time "you can press the red Next button" hint has been spoken this process. */
    private var announcedNextButton = false

    private fun announceNextButtonOnce() {
        if (announcedNextButton) return
        announcedNextButton = true
        WayloGuidanceService.instance?.speaker?.speakQueued(
            "You can press the red Next button on the right side to move to the next step."
        )
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
        val whichCheck: String
        val result: Boolean
        if (index == 0) {
            whichCheck = "isLauncherPackage"
            result = ElementFinder.isLauncherPackage(fg)
        } else {
            whichCheck = "packageEquality"
            result = expectedAppPackage == null || fg == expectedAppPackage
        }
        if (!result) {
            WayloVerify.d("WRONG_LOCATION | stepIndex=$index | currentPackage=$fg | " +
                    "expectedPackage=${expectedAppPackage ?: "null(launcher)"} | whichCheckFailed=$whichCheck | " +
                    "compared=(current=$fg vs expected=${expectedAppPackage ?: "any launcher"})"
            )
        }
        return result
    }

    /**
     * FIX item 3: known/likely transient system-overlay packages that can
     * briefly appear in TYPE_WINDOW_STATE_CHANGED/TYPE_WINDOW_CONTENT_CHANGED
     * events without the user having actually left the target app — a
     * screen-recorder toggle notification, the notification shade, a
     * permission/system dialog, or an IME popping up. Exact-match set for
     * well-known packages observed or documented; OEM-specific variants
     * (e.g. non-Pixel screen recorders/keyboards) are caught by
     * [TRANSIENT_PACKAGE_PATTERNS] below instead of trying to enumerate
     * every OEM's package name.
     */
    private val TRANSIENT_PACKAGES = setOf(
        "com.android.systemui", // notification shade, quick settings, recents, volume panel, system dialogs
        "com.oplus.screenrecorder", // the exact package from the reported run
        "com.google.android.permissioncontroller", // Android runtime-permission dialogs
        "com.android.permissioncontroller", // AOSP naming variant on some OS versions
        "com.google.android.inputmethod.latin", // Gboard
        "com.samsung.android.honeyboard",
        "com.touchtype.swiftkey"
    )

    /**
     * Substring patterns catching screen-recorder/IME package name variants
     * across OEMs not worth enumerating individually — e.g. Samsung/Xiaomi/
     * other skins each ship their own screen-recorder and keyboard app under
     * a different package, but they overwhelmingly contain one of these
     * words.
     */
    private val TRANSIENT_PACKAGE_PATTERNS = listOf(
        Regex("screenrecord", RegexOption.IGNORE_CASE), // covers screenrecord AND screenrecorder
        Regex("inputmethod", RegexOption.IGNORE_CASE)
    )

    /**
     * Whether [pkg] is a known/likely transient system overlay (see
     * [TRANSIENT_PACKAGES]/[TRANSIENT_PACKAGE_PATTERNS]) rather than a
     * genuine app the user navigated to — such packages must never
     * overwrite [lastKnownForegroundPackage] or be treated as "the user
     * left the app" (see [onWindowStateChanged]/[onContentChanged]).
     * `internal` for unit-testability, same rationale as [isInExpectedApp].
     */
    internal fun isTransientForegroundPackage(pkg: String): Boolean =
        pkg in TRANSIENT_PACKAGES || TRANSIENT_PACKAGE_PATTERNS.any { it.containsMatchIn(pkg) }

    /**
     * BUG-2/BUG-3: subset of [TRANSIENT_PACKAGES]/[TRANSIENT_PACKAGE_PATTERNS]
     * that are specifically IME/keyboard packages, as opposed to screen
     * recorders or system dialogs — used to track [imeLikelyVisible]
     * separately, since "an IME is probably up" is a more specific,
     * actionable signal for speech/mic-prompt suppression than "some
     * transient overlay is up." Deliberately a small, separate list (not
     * derived from [TRANSIENT_PACKAGES]) so this concern stays independently
     * readable, matching this file's existing style of plain, explicit sets.
     */
    private val IME_PACKAGES = setOf(
        "com.google.android.inputmethod.latin", // Gboard
        "com.samsung.android.honeyboard",
        "com.touchtype.swiftkey"
    )

    private val IME_PACKAGE_PATTERN = Regex("inputmethod", RegexOption.IGNORE_CASE)

    /**
     * Whether [pkg] is specifically a known/likely IME package (a subset of
     * [isTransientForegroundPackage]'s broader check). `internal` for
     * unit-testability, same rationale as [isInExpectedApp].
     */
    internal fun isImePackage(pkg: String): Boolean =
        pkg in IME_PACKAGES || IME_PACKAGE_PATTERN.containsMatchIn(pkg)

    /**
     * BUG 3: keeps the mic overlay off the keyboard — hides it while a
     * TEXT_INPUT step is active or [imeLikelyVisible], re-shows it (with the
     * same tap handler it was first shown with, see
     * [OverlayManager.setMicButtonSuppressed]) once neither applies. Only
     * meaningful during an active run — [taskComplete] tears the mic button
     * down completely and separately (not via this function), so this
     * always no-ops once guidance has stopped, and can never undo that
     * teardown just because an unrelated window-state event fires afterward
     * (which happens constantly, for every app on the device, not just
     * Waylo's).
     */
    private fun updateMicButtonVisibility() {
        if (!isRunning) return
        val suppress = imeLikelyVisible || currentVerification is Verification.TextInput
        OverlayManager.setMicButtonSuppressed(suppress)
    }

    /**
     * BUG 3: whether [com.waylo.correction.CorrectionFlow.start] should
     * refuse to run right now — while a TEXT_INPUT step is active, or an
     * IME/keyboard is likely visible ([imeLikelyVisible]). The mic button
     * sits bottom-right, the same region a keyboard occupies, so an ordinary
     * typing tap can accidentally land on it instead of the keyboard; this
     * guard is what stops that from repeatedly triggering "What went wrong?"
     * while the user is simply trying to type (a real capture showed this
     * happening). Also covers the volume-down double-press entry point,
     * which works independent of the mic button's own visibility. `fun`
     * (not `internal`) since [com.waylo.correction.CorrectionFlow] is a
     * different package.
     */
    fun shouldSuppressCorrectionPrompt(): Boolean =
        imeLikelyVisible || (isRunning && currentVerification is Verification.TextInput)

    /**
     * FIX: whether a confident element match this scan is happening DESPITE
     * the foreground-package check failing — i.e. whether to log
     * `PLACEMENT_OVERRIDES_PACKAGE`. This is a named, testable predicate for
     * this fix's core contract ("a confident element match always places the
     * dot, even when the package reading says wrong app/transient overlay")
     * — used by both [locateStep] and [revalidatePlacement] at the exact
     * point they've already found a confident result and are about to place/
     * keep the dot, specifically for the reported scenario: the foreground
     * package momentarily read as a transient overlay
     * (com.oplus.screenrecorder, com.android.systemui, etc.) instead of the
     * real app. The actual PLACEMENT decision lives in each function's
     * control flow (a confident result always returns/continues before the
     * package check is even consulted — see their comments); this function
     * only decides whether that placement counts as an "override" worth
     * logging. `internal` for unit-testability, same rationale as
     * [isInExpectedApp].
     */
    internal fun isPlacementOverridingPackageMismatch(index: Int, foregroundPackage: String?, expectedAppPackage: String?): Boolean =
        !isInExpectedApp(index, foregroundPackage, expectedAppPackage)


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

    /**
     * Only reachable via [advanceFrom] on the verified last step — never a
     * bare timeout.
     *
     * BUG 3: tears down the mic/feedback overlay the same moment the dot/
     * arrow hide and "task complete" is spoken — a real capture showed it
     * lingering indefinitely after completion (it was previously only ever
     * torn down in [WayloGuidanceService.onDestroy], i.e. full service
     * shutdown). This is a full, permanent teardown (unlike
     * [updateMicButtonVisibility]'s transient per-step suppress/restore) —
     * the mic becomes guidance-run-scoped by this fix rather than
     * service-lifetime-scoped; re-showing it for a subsequent task is a
     * follow-up product decision, not part of this fix.
     */
    private fun taskComplete() {
        if (!isRunning) return // idempotent — guards a stale continuation racing a genuine completion
        stepJob?.cancel()
        stepJob = null
        currentStepScope = null
        currentStepPhase = null
        OverlayManager.hideDot()
        OverlayManager.hideArrow()
        OverlayManager.hideMicButton()
        OverlayManager.hideNextButton()
        WayloGuidanceService.instance?.speaker?.speak("All done! Task complete.")
        isRunning = false
        Log.e(TAG, "Task complete: '$currentTask'")
        RunReport.endRun("completed")
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
