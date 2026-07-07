package com.waylo.guidance

import android.content.Context
import android.graphics.Bitmap
import android.util.Base64
import android.util.Log
import com.waylo.BuildConfig
import com.waylo.ai.FailureReportClient
import com.waylo.ai.GeminiVisionClient
import com.waylo.ai.Step
import com.waylo.ai.YoloDetectionClient
import com.waylo.ocr.OcrAnalyzer
import com.waylo.screenshot.ScreenCaptureManager
import com.waylo.service.WayloGuidanceService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import kotlin.coroutines.resume

/**
 * Fallback chain used by [GuidanceEngine] when Layer 1 (accessibility tree)
 * fails to locate the target element.
 *
 *   Layer 2  — ML Kit OCR over a screenshot (via existing [OcrAnalyzer]).
 *   Layer 2b — YOLO object detector on EC2 (via [YoloDetectionClient]), gated
 *              by [YoloDetectionClient.YOLO_LAYER_ENABLED]. Tried after OCR
 *              misses, before the (slower, paid) Gemini Vision call below.
 *   Layer 3a — Gemini Vision LOCATE: "I expect X, where is it?" → coordinates.
 *   Layer 3b — Gemini Vision TROUBLESHOOT: "X is missing, what should the user
 *              do?" → recovery steps that splice into the remaining plan.
 *
 * Implemented as an object so it can be called from the [GuidanceEngine]
 * singleton without dependency injection. Heavy work runs on [Dispatchers.IO].
 */
object FallbackHandler {

    private const val TAG = "WAYLO_DOT"

    /** Outcome of the fallback chain. */
    sealed class FallbackResult {
        /** Found it — put the dot at this screen coordinate. */
        data class Found(val x: Int, val y: Int, val updatedInstruction: String?) : FallbackResult()

        /** Gemini analysed the screen and produced new steps to continue from here. */
        data class NewSteps(val steps: List<Step>, val explanation: String) : FallbackResult()

        /** Could not recover. */
        data class Failed(val reason: String) : FallbackResult()
    }

    /** Fire-and-forget scope for opt-in success-pair logging — must never delay returning a real result to the caller. */
    private val loggingScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private fun speak(text: String) {
        WayloGuidanceService.instance?.speaker?.speak(text)
    }

    /**
     * Run the fallback chain.
     *
     * @param context            used for screen capture.
     * @param task               full user task, e.g. "open youtube history".
     * @param stepIndex          current step index (0-based).
     * @param totalSteps         total steps in the plan.
     * @param findDesc           what we're looking for, e.g. "History tab youtube library".
     * @param alternateLabels    extra labels from the step's enriched metadata (may be empty) — used by the OCR pass only; the YOLO service matches server-side instead.
     * @param visualDescription  free-text visual description from the step's enriched metadata (may be null) — used by the OCR pass only.
     * @param instruction        the step's plain-English instruction — sent to the YOLO service as `step_instruction`.
     * @param screenRegion       the step's enriched screen-region hint (may be null) — sent to the YOLO service as `screen_region`.
     */
    suspend fun handle(
        context: Context,
        task: String,
        stepIndex: Int,
        totalSteps: Int,
        findDesc: String,
        alternateLabels: List<String> = emptyList(),
        visualDescription: String? = null,
        instruction: String? = null,
        screenRegion: String? = null
    ): FallbackResult = withContext(Dispatchers.IO) {
        Log.d(TAG, "Fallback triggered for step $stepIndex: $findDesc")

        // ── Layer 2: ML Kit OCR ───────────────────────────────────────────
        speak("Let me look at your screen...")
        val bitmap = captureBitmap(context)
        if (bitmap != null) {
            try {
                val elements = OcrAnalyzer.analyzeScreen(bitmap)
                val match = OcrAnalyzer.findBestMatch(elements, findDesc, visualDescription, alternateLabels)
                if (match != null) {
                    Log.d(TAG, "Layer 2 OCR hit '${match.text}' at (${match.centerX},${match.centerY})")
                    return@withContext FallbackResult.Found(match.centerX, match.centerY, null)
                }
                Log.d(TAG, "Layer 2 OCR miss for '$findDesc'")
            } catch (e: Exception) {
                Log.e(TAG, "Layer 2 OCR threw", e)
            } finally {
                if (!bitmap.isRecycled) bitmap.recycle()
            }
        } else {
            Log.w(TAG, "Layer 2: couldn't capture screen")
        }

        // ── Layer 2b: YOLO object detector (EC2) ──────────────────────────
        if (YoloDetectionClient.YOLO_LAYER_ENABLED) {
            speak("Let me take a closer look...")
            val yoloBitmap = captureBitmap(context)
            if (yoloBitmap != null) {
                try {
                    val yoloMatch = YoloDetectionClient.detectAndMatch(
                        bitmap = yoloBitmap,
                        findDescription = findDesc,
                        instruction = instruction,
                        screenRegion = screenRegion
                    )
                    if (yoloMatch != null) {
                        Log.d(
                            TAG,
                            "Layer 2b YOLO hit confidence=${yoloMatch.confidence} at (${yoloMatch.centerX},${yoloMatch.centerY}) " +
                                "source=${yoloMatch.source} ax_class=${yoloMatch.axClass}"
                        )
                        // Opt-in (see BuildConfig.LOG_YOLO_SUCCESSES): log this
                        // hit as a training pair too, not just misses. Fire-
                        // and-forget — must never delay placing the dot.
                        if (BuildConfig.LOG_YOLO_SUCCESSES) {
                            loggingScope.launch {
                                FailureReportClient.reportAutoSuccess(
                                    sessionId = GuidanceEngine.getSessionId(),
                                    stepNumber = stepIndex + 1,
                                    findDescription = findDesc,
                                    targetPackage = GuidanceEngine.getCurrentAppPackage(),
                                    chosenBox = FailureReportClient.ChosenBox(
                                        centerX = yoloMatch.centerX,
                                        centerY = yoloMatch.centerY,
                                        confidence = yoloMatch.confidence,
                                        source = yoloMatch.source,
                                        axClass = yoloMatch.axClass
                                    ),
                                    screenshotHash = yoloMatch.screenshotHash
                                )
                            }
                        }
                        return@withContext FallbackResult.Found(yoloMatch.centerX, yoloMatch.centerY, null)
                    }
                    Log.d(TAG, "Layer 2b YOLO miss/low-confidence for '$findDesc'")
                } catch (e: Exception) {
                    Log.e(TAG, "Layer 2b YOLO threw", e)
                } finally {
                    if (!yoloBitmap.isRecycled) yoloBitmap.recycle()
                }
            } else {
                Log.w(TAG, "Layer 2b: couldn't capture screen")
            }
        }

        // ── Layer 3a: Gemini Vision LOCATE ────────────────────────────────
        speak("One moment, checking your screen...")
        val screenshotBase64 = captureBase64(context)
            ?: return@withContext FallbackResult.Failed("Could not capture screen")

        val locate = GeminiVisionClient.locate(
            screenshotBase64 = screenshotBase64,
            task = task,
            currentStepIndex = stepIndex,
            totalSteps = totalSteps,
            findDescription = findDesc
        )
        if (locate != null && locate.found && locate.x > 0) {
            Log.d(TAG, "Layer 3a located element at (${locate.x},${locate.y})")
            return@withContext FallbackResult.Found(
                locate.x, locate.y, locate.instruction.ifBlank { null }
            )
        }
        Log.d(TAG, "Layer 3a: element not on screen. Escalating to troubleshoot.")

        // ── Layer 3b: Gemini Vision TROUBLESHOOT ──────────────────────────
        speak("I see something unexpected. Let me figure out what to do...")
        val troubleshootShot = captureBase64(context) ?: screenshotBase64
        val troubleshoot = GeminiVisionClient.troubleshoot(
            screenshotBase64 = troubleshootShot,
            task = task,
            currentStepIndex = stepIndex,
            totalSteps = totalSteps,
            findDescription = findDesc
        )
        if (troubleshoot != null && troubleshoot.recoverable && troubleshoot.newSteps.isNotEmpty()) {
            Log.d(TAG, "Layer 3b: ${troubleshoot.newSteps.size} recovery steps. ${troubleshoot.explanation}")
            return@withContext FallbackResult.NewSteps(troubleshoot.newSteps, troubleshoot.explanation)
        }

        val reason = troubleshoot?.explanation ?: "The element was not found on screen"
        Log.d(TAG, "Layer 3b: unrecoverable. $reason")
        return@withContext FallbackResult.Failed(reason)
    }

    /** Bridge the existing callback-based capture into a coroutine. */
    private suspend fun captureBitmap(context: Context): Bitmap? =
        suspendCancellableCoroutine { cont ->
            ScreenCaptureManager.captureScreen(context) { bitmap ->
                if (cont.isActive) cont.resume(bitmap)
            }
        }

    /** Capture a screenshot and encode it as a Base64 JPEG for the backend. */
    private suspend fun captureBase64(context: Context): String? {
        val bitmap = captureBitmap(context) ?: return null
        return try {
            val baos = ByteArrayOutputStream()
            // 70% quality keeps the payload (and Gemini token count) reasonable.
            bitmap.compress(Bitmap.CompressFormat.JPEG, 70, baos)
            Base64.encodeToString(baos.toByteArray(), Base64.NO_WRAP)
        } catch (e: Exception) {
            Log.e(TAG, "captureBase64 failed", e)
            null
        } finally {
            if (!bitmap.isRecycled) bitmap.recycle()
        }
    }
}
