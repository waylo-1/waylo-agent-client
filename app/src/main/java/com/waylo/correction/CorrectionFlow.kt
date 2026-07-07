package com.waylo.correction

import android.content.Context
import android.content.Intent
import android.graphics.Rect
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.util.Log
import android.view.accessibility.AccessibilityNodeInfo
import com.waylo.accessibility.WayloAccessibilityService
import com.waylo.ai.FailureReportClient
import com.waylo.guidance.GuidanceEngine
import com.waylo.service.WayloGuidanceService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay
import java.util.Locale

/**
 * User-feedback correction flow — the training-data flywheel for detection
 * misses the user notices but the app didn't (or got wrong). Entry points:
 * a volume-down double-press (see
 * [com.waylo.accessibility.WayloAccessibilityService.onKeyEvent]) or a tap
 * on the persistent mic button (see
 * [com.waylo.overlay.OverlayManager.showMicButton]) — both call [start].
 *
 * Sequence: speak "What went wrong?" -> listen via [SpeechRecognizer] ->
 * if the user says anything, give them [AWAITING_TAP_WINDOW_MS] to tap the
 * element that's actually correct (captured via [onNodeClicked], fed every
 * TYPE_VIEW_CLICKED event by the accessibility service) -> POST everything
 * gathered to the backend's `/failure` endpoint
 * ([FailureReportClient.reportUserCorrection], `source=user_correction`).
 *
 * A correction text alone (no tap) is still submitted — the tap is a bonus,
 * not a requirement.
 */
object CorrectionFlow {

    private const val TAG = "WAYLO_DOT"

    /** How long after a spoken correction we still accept a "the correct one is here" tap. */
    private const val AWAITING_TAP_WINDOW_MS = 15_000L

    /** Gives the "What went wrong?" prompt a moment to finish before the mic starts listening. */
    private const val LISTEN_START_DELAY_MS = 1200L

    private enum class State { IDLE, LISTENING, AWAITING_TAP }

    private var state = State.IDLE
    private var pendingCorrectionText: String? = null
    private var recognizer: SpeechRecognizer? = null
    private var awaitingTapJob: Job? = null
    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    /** Begin the flow. A no-op if one is already in progress (a rapid double-press + mic tap shouldn't overlap two prompts). */
    fun start() {
        if (state != State.IDLE) {
            Log.d(TAG, "CorrectionFlow.start: already in progress (state=$state), ignoring.")
            return
        }
        val context = WayloAccessibilityService.instance ?: run {
            Log.w(TAG, "CorrectionFlow.start: accessibility service not connected, can't run the correction flow.")
            return
        }
        state = State.LISTENING
        pendingCorrectionText = null
        WayloGuidanceService.instance?.speaker?.speak("What went wrong?")
        scope.launch {
            delay(LISTEN_START_DELAY_MS)
            if (state == State.LISTENING) startListening(context)
        }
    }

    private fun startListening(context: Context) {
        if (!SpeechRecognizer.isRecognitionAvailable(context)) {
            Log.w(TAG, "CorrectionFlow: no speech recognition service available on this device.")
            state = State.IDLE
            return
        }
        val rec = SpeechRecognizer.createSpeechRecognizer(context)
        recognizer = rec
        rec.setRecognitionListener(object : RecognitionListener {
            override fun onResults(results: Bundle) {
                val text = results.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()
                Log.d(TAG, "CorrectionFlow: heard '$text'")
                onTranscript(text)
            }
            override fun onError(error: Int) {
                Log.w(TAG, "CorrectionFlow: recognition error code=$error")
                onTranscript(null)
            }
            override fun onReadyForSpeech(params: Bundle?) {}
            override fun onBeginningOfSpeech() {}
            override fun onRmsChanged(rmsdB: Float) {}
            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() {}
            override fun onPartialResults(partialResults: Bundle?) {}
            override fun onEvent(eventType: Int, params: Bundle?) {}
        })
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, Locale.getDefault())
            putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, context.packageName)
        }
        rec.startListening(intent)
    }

    private fun onTranscript(text: String?) {
        recognizer?.destroy()
        recognizer = null
        val correctionText = text?.takeIf { it.isNotBlank() }
        pendingCorrectionText = correctionText

        if (correctionText == null) {
            Log.d(TAG, "CorrectionFlow: no usable transcript, submitting without one.")
            submit(correctedTarget = null)
            return
        }

        state = State.AWAITING_TAP
        awaitingTapJob?.cancel()
        awaitingTapJob = scope.launch {
            delay(AWAITING_TAP_WINDOW_MS)
            if (state == State.AWAITING_TAP) {
                Log.d(TAG, "CorrectionFlow: awaiting-tap window elapsed with no tap, submitting text-only.")
                submit(correctedTarget = null)
            }
        }
    }

    /** Fed every TYPE_VIEW_CLICKED event by the accessibility service — only acts while [State.AWAITING_TAP]. */
    fun onNodeClicked(node: AccessibilityNodeInfo?) {
        if (state != State.AWAITING_TAP || node == null) return
        awaitingTapJob?.cancel()
        val bounds = Rect()
        node.getBoundsInScreen(bounds)
        val target = FailureReportClient.CorrectedTarget(
            bounds = bounds,
            text = node.text?.toString(),
            contentDescription = node.contentDescription?.toString(),
            viewId = node.viewIdResourceName
        )
        Log.d(TAG, "CorrectionFlow: captured corrected target: $target")
        submit(target)
    }

    private fun submit(correctedTarget: FailureReportClient.CorrectedTarget?) {
        val correctionText = pendingCorrectionText
        state = State.IDLE
        pendingCorrectionText = null
        val step = GuidanceEngine.getCurrentStep()
        scope.launch {
            FailureReportClient.reportUserCorrection(
                sessionId = GuidanceEngine.getSessionId(),
                taskDescription = GuidanceEngine.getCurrentTaskDescription(),
                stepNumber = GuidanceEngine.getCurrentStepNumber(),
                findDescription = step?.findDescription ?: "unknown (no active guidance step)",
                correctionText = correctionText,
                correctedTarget = correctedTarget,
                currentPackage = GuidanceEngine.getLastKnownForegroundPackage(),
                currentActivity = WayloAccessibilityService.instance?.lastActivityClassName
            )
        }
    }
}
