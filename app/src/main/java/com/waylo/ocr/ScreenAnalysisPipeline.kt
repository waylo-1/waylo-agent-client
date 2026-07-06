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
 *  Layer 3 — Gemini Vision. Not called from this file: when both layers here
 *  miss, GuidanceEngine escalates to FallbackHandler.kt, which re-checks OCR
 *  and then calls GeminiVisionClient (locate/troubleshoot) against the backend.
 *
 * All heavy work runs on [Dispatchers.IO]; callers marshal the result back to
 * the main thread as needed.
 */
object ScreenAnalysisPipeline {

    private const val TAG = "Waylo"

    data class PipelineResult(
        val x: Int,
        val y: Int,
        val source: String, // "accessibility", "ocr", "gemini", "failed"
        val confidence: Float,
        val label: String
    )

    /**
     * Run the full pipeline for [description] and return the best result.
     * [targetPackage], [alternateLabels] and [visualDescription] are optional
     * enriched-step hints from the backend plan (may be absent on older/cached
     * plans) that give Layer 1/Layer 2 a little more to match against.
     */
    suspend fun analyze(
        context: Context,
        description: String,
        targetPackage: String? = null,
        alternateLabels: List<String> = emptyList(),
        visualDescription: String? = null
    ): PipelineResult =
        withContext(Dispatchers.IO) {
            // --- Layer 1: accessibility tree ---
            Log.e("WAYLO_DOT", "Pipeline layer 1 starting for: $description")
            val match = ElementFinder.findElement(description, targetPackage, alternateLabels)
            Log.e("WAYLO_DOT", "Layer 1 result: ${match?.score} score, node: ${match?.node?.contentDescription}")
            if (match != null && match.isConfident()) {
                val bounds = ElementFinder.getBoundsOnScreen(match.node)
                val label = match.node.text?.toString()
                    ?: match.node.contentDescription?.toString()
                    ?: description
                Log.d(TAG, "Pipeline: Layer 1 (accessibility) hit, score=${match.score}.")
                val r = PipelineResult(
                    x = bounds.centerX(),
                    y = bounds.centerY(),
                    source = "accessibility",
                    confidence = match.score.toFloat(),
                    label = label
                )
                Log.e("WAYLO_DOT", "Final pipeline result: source=${r.source} x=${r.x} y=${r.y}")
                return@withContext r
            }
            Log.d(TAG, "Pipeline: Layer 1 insufficient (score=${match?.score ?: 0}), trying OCR.")

            // --- Layer 2: screen capture + OCR ---
            Log.e("WAYLO_DOT", "Pipeline layer 2 starting (OCR)")
            val bitmap = captureScreenSuspend(context)
            if (bitmap != null) {
                try {
                    val elements = OcrAnalyzer.analyzeScreen(bitmap)
                    val ocrMatch = OcrAnalyzer.findBestMatch(elements, description, visualDescription, alternateLabels)
                    Log.e("WAYLO_DOT", "Layer 2 result: ${ocrMatch?.text} at ${ocrMatch?.centerX},${ocrMatch?.centerY}")
                    if (ocrMatch != null) {
                        Log.d(TAG, "Pipeline: Layer 2 (OCR) hit '${ocrMatch.text}'.")
                        val r = PipelineResult(
                            x = ocrMatch.centerX,
                            y = ocrMatch.centerY,
                            source = "ocr",
                            confidence = ocrMatch.confidence,
                            label = ocrMatch.text
                        )
                        Log.e("WAYLO_DOT", "Final pipeline result: source=${r.source} x=${r.x} y=${r.y}")
                        return@withContext r
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Pipeline: OCR layer threw.", e)
                } finally {
                    // Never retain screenshots: recycle as soon as OCR is done.
                    if (!bitmap.isRecycled) bitmap.recycle()
                }
            } else {
                Log.e("WAYLO_DOT", "Layer 2 capture returned null (no screen-capture permission?).")
            }

            // --- Layer 3: Gemini Vision ---
            // Implemented, but not invoked from this pipeline. GuidanceEngine calls
            // FallbackHandler.handle() (see FallbackHandler.kt) when this function
            // returns "failed", and that's where the Gemini Vision calls happen.
            Log.e("WAYLO_DOT", "All layers failed for: $description")
            val failed = PipelineResult(0, 0, "failed", 0f, description)
            Log.e("WAYLO_DOT", "Final pipeline result: source=${failed.source} x=${failed.x} y=${failed.y}")
            failed
        }

    /**
     * Convenience alias used by GuidanceEngine: run the pipeline and return the
     * result (does not place the dot).
     */
    suspend fun find(
        context: Context,
        description: String,
        targetPackage: String? = null,
        alternateLabels: List<String> = emptyList(),
        visualDescription: String? = null
    ): PipelineResult =
        analyze(context, description, targetPackage, alternateLabels, visualDescription)

    /**
     * Convenience: run the pipeline then place/move the dot on the result.
     * Returns the result so the caller can surface a toast/log.
     */
    suspend fun findAndShow(
        context: Context,
        description: String,
        targetPackage: String? = null,
        alternateLabels: List<String> = emptyList(),
        visualDescription: String? = null
    ): PipelineResult {
        val result = analyze(context, description, targetPackage, alternateLabels, visualDescription)
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
