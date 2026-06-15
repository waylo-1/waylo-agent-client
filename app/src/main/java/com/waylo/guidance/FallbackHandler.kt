package com.waylo.guidance

import android.content.Context
import android.graphics.Bitmap
import android.util.Base64
import android.util.Log
import com.waylo.ai.GeminiVisionClient
import com.waylo.ai.Step
import com.waylo.ocr.OcrAnalyzer
import com.waylo.screenshot.ScreenCaptureManager
import com.waylo.service.WayloGuidanceService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import kotlin.coroutines.resume

/** Encode a bitmap as a Base64 JPEG (60% quality — enough for analysis/training). */
fun Bitmap.toBase64(): String {
    val stream = ByteArrayOutputStream()
    this.compress(Bitmap.CompressFormat.JPEG, 60, stream)
    return Base64.encodeToString(stream.toByteArray(), Base64.NO_WRAP)
}

/**
 * Fallback chain used by [GuidanceEngine] when Layer 1 (accessibility tree)
 * fails to locate the target element.
 *
 *   Layer 2  — ML Kit OCR over a screenshot (via existing [OcrAnalyzer]).
 *   Layer 3a — Gemini Vision LOCATE: "I expect X, where is it?" → coordinates.
 *   Layer 3b — Gemini Vision TROUBLESHOOT: "X is missing, what should the user
 *              do?" → recovery steps that splice into the remaining plan.
 *
 * Before escalating to the vision layer (L3), if every local layer (L0/L1/L2)
 * has missed, a structured [DetectionFailure] is logged via [FailureLogger] so
 * the miss becomes future YOLO training data instead of a silent wasted call.
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

    private fun speak(text: String) {
        WayloGuidanceService.instance?.speaker?.speak(text)
    }

    /**
     * Run the fallback chain.
     *
     * @param context     used for screen capture.
     * @param task        full user task, e.g. "open youtube history".
     * @param stepIndex   current step index (0-based).
     * @param totalSteps  total steps in the plan.
     * @param step        rich metadata describing the element we're looking for.
     * @param targetPackage  the target app package (for failure logging).
     * @param sessionId   UUID for the current guidance session (for failure logging).
     */
    suspend fun handle(
        context: Context,
        task: String,
        stepIndex: Int,
        totalSteps: Int,
        step: StepMetadata,
        targetPackage: String,
        sessionId: String
    ): FallbackResult = withContext(Dispatchers.IO) {
        val findDesc = step.findDescription
        Log.d(TAG, "Fallback triggered for step $stepIndex: $findDesc")

        // Layer that was last attempted before vision. L0 (accessibility) ran in
        // the pipeline upstream; here we attempt L1 (OCR). Tracked for the
        // failure record so the YOLO export knows how far detection got.
        var lastLayerAttempted = 0

        // ── Layer 2 (L1): ML Kit OCR ──────────────────────────────────────
        speak("Let me look at your screen...")
        val ocrBitmap = captureBitmap(context)
        if (ocrBitmap != null) {
            lastLayerAttempted = 1
            try {
                val elements = OcrAnalyzer.analyzeScreen(ocrBitmap)
                val match = OcrAnalyzer.findBestMatch(elements, findDesc)
                if (match != null) {
                    Log.d(TAG, "Layer 2 OCR hit '${match.text}' at (${match.centerX},${match.centerY})")
                    return@withContext FallbackResult.Found(match.centerX, match.centerY, null)
                }
                Log.d(TAG, "Layer 2 OCR miss for '$findDesc'")
            } catch (e: Exception) {
                Log.e(TAG, "Layer 2 OCR threw", e)
            } finally {
                if (!ocrBitmap.isRecycled) ocrBitmap.recycle()
            }
        } else {
            Log.w(TAG, "Layer 2: couldn't capture screen")
        }

        // ── All local layers (L0/L1/L2) missed — flag the failure ─────────
        // Fire-and-forget: never blocks or crashes the guidance flow. We still
        // proceed to the vision fallback (L3) immediately afterwards.
        captureBitmap(context)?.let { flagBitmap ->
            try {
                val failure = DetectionFailure(
                    sessionId = sessionId,
                    taskDescription = task,
                    stepNumber = step.stepNumber,
                    findDescription = step.findDescription,
                    elementType = step.elementType.name,
                    screenRegion = step.screenRegion.name,
                    visualDescription = step.visualDescription,
                    targetPackage = targetPackage,
                    layerReached = lastLayerAttempted,
                    screenshotBase64 = flagBitmap.toBase64(),
                    screenWidth = flagBitmap.width,
                    screenHeight = flagBitmap.height
                )
                FailureLogger.logFailure(failure)
            } finally {
                if (!flagBitmap.isRecycled) flagBitmap.recycle()
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
