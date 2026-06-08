package com.waylo.ocr

import android.content.Context
import android.graphics.Bitmap
import android.util.Log
import com.waylo.accessibility.ElementFinder
import com.waylo.overlay.OverlayManager
import com.waylo.screenshot.ScreenCaptureManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlin.coroutines.resume

/**
 * Three-layer orchestrator that decides where the dot should go for a given
 * element [description]:
 *
 *  Layer 1 — accessibility tree (ElementFinder). Used if score > 50.
 *  Layer 2 — screen capture + ML Kit OCR.
 *  Layer 3 — Gemini Vision (stubbed until Week 2).
 *
 * All heavy work runs on [Dispatchers.IO]; callers marshal the result back to
 * the main thread as needed.
 */
object ScreenAnalysisPipeline {

    private const val TAG = "Waylo"
    private const val ACCESSIBILITY_CONFIDENCE = 50

    data class PipelineResult(
        val x: Int,
        val y: Int,
        val source: String, // "accessibility", "ocr", "gemini", "failed"
        val confidence: Float,
        val label: String
    )

    /**
     * Run the full pipeline for [description] and return the best result.
     */
    suspend fun analyze(context: Context, description: String): PipelineResult =
        withContext(Dispatchers.IO) {
            // --- Layer 1: accessibility tree ---
            val match = ElementFinder.findElement(description)
            if (match != null && match.score > ACCESSIBILITY_CONFIDENCE) {
                val bounds = ElementFinder.getBoundsOnScreen(match.node)
                val label = match.node.text?.toString()
                    ?: match.node.contentDescription?.toString()
                    ?: description
                Log.d(TAG, "Pipeline: Layer 1 (accessibility) hit, score=${match.score}.")
                return@withContext PipelineResult(
                    x = bounds.centerX(),
                    y = bounds.centerY(),
                    source = "accessibility",
                    confidence = match.score.toFloat(),
                    label = label
                )
            }
            Log.d(TAG, "Pipeline: Layer 1 insufficient (score=${match?.score ?: 0}), trying OCR.")

            // --- Layer 2: screen capture + OCR ---
            val bitmap = captureScreenSuspend(context)
            if (bitmap != null) {
                try {
                    val elements = OcrAnalyzer.analyzeScreen(bitmap)
                    val ocrMatch = OcrAnalyzer.findBestMatch(elements, description)
                    if (ocrMatch != null) {
                        Log.d(TAG, "Pipeline: Layer 2 (OCR) hit '${ocrMatch.text}'.")
                        return@withContext PipelineResult(
                            x = ocrMatch.centerX,
                            y = ocrMatch.centerY,
                            source = "ocr",
                            confidence = ocrMatch.confidence,
                            label = ocrMatch.text
                        )
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Pipeline: OCR layer threw.", e)
                } finally {
                    // Never retain screenshots: recycle as soon as OCR is done.
                    if (!bitmap.isRecycled) bitmap.recycle()
                }
            } else {
                Log.d(TAG, "Pipeline: Layer 2 capture returned null.")
            }

            // --- Layer 3: Gemini Vision (stub) ---
            // TODO: Week 2 — send the screenshot to Gemini Vision via the backend.
            Log.d(TAG, "All layers failed for: $description")
            PipelineResult(0, 0, "failed", 0f, description)
        }

    /**
     * Convenience: run the pipeline then place/move the dot on the result.
     * Returns the result so the caller can surface a toast/log.
     */
    suspend fun findAndShow(context: Context, description: String): PipelineResult {
        val result = analyze(context, description)
        if (result.source != "failed") {
            withContext(Dispatchers.Main) {
                OverlayManager.showDotAtResult(result)
            }
        }
        return result
    }

    /** Bridge ScreenCaptureManager's callback API into a coroutine. */
    private suspend fun captureScreenSuspend(context: Context): Bitmap? =
        suspendCancellableCoroutine { cont ->
            ScreenCaptureManager.captureScreen(context) { bitmap ->
                if (cont.isActive) cont.resume(bitmap)
            }
        }
}
