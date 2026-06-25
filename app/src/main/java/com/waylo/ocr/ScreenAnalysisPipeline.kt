package com.waylo.ocr

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Point
import android.util.Log
import android.view.WindowManager
import com.waylo.accessibility.ElementFinder
import com.waylo.accessibility.WayloAccessibilityService
import com.waylo.guidance.StepMetadata
import com.waylo.ml.YOLOv8Detector
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

    // Lazily-created L2 detector. Null if the model asset isn't bundled yet
    // (L2 is then skipped). We attempt creation once to avoid repeated IO.
    @Volatile
    private var yolo: YOLOv8Detector? = null
    @Volatile
    private var yoloAttempted = false

    private fun yoloDetector(context: Context): YOLOv8Detector? {
        if (yoloAttempted) return yolo
        synchronized(this) {
            if (yoloAttempted) return yolo
            yolo = YOLOv8Detector.create(context)
            yoloAttempted = true
            return yolo
        }
    }

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
            Log.e("WAYLO_DOT", "Pipeline layer 1 starting for: $description")
            val match = ElementFinder.findElement(description)
            Log.e("WAYLO_DOT", "Layer 1 result: ${match?.score} score, node: ${match?.node?.contentDescription}")
            if (match != null && match.score > ACCESSIBILITY_CONFIDENCE) {
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
                    val ocrMatch = OcrAnalyzer.findBestMatch(elements, description)
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

            // --- Layer 3: Gemini Vision (stub) ---
            // TODO: Week 2 — send the screenshot to Gemini Vision via the backend.
            Log.e("WAYLO_DOT", "All layers failed for: $description")
            val failed = PipelineResult(0, 0, "failed", 0f, description)
            Log.e("WAYLO_DOT", "Final pipeline result: source=${failed.source} x=${failed.x} y=${failed.y}")
            failed
        }

    /**
     * Convenience alias used by GuidanceEngine: run the pipeline and return the
     * result (does not place the dot).
     */
    suspend fun find(context: Context, description: String): PipelineResult =
        analyze(context, description)

    /**
     * Enriched pipeline: run L0 (accessibility via [SemanticMatcher]) then
     * L1 (OCR via [SemanticMatcher]) against rich [step] metadata.
     *
     * Returns a [PipelineResult] whose source is "accessibility" or "ocr" on a
     * hit, or "failed" if both layers miss. [targetPackage] biases L0 toward the
     * real app's nodes. Used by [com.waylo.guidance.GuidanceEngine].
     */
    suspend fun find(
        context: Context,
        step: StepMetadata,
        targetPackage: String,
        screenWidth: Int,
        screenHeight: Int
    ): PipelineResult = withContext(Dispatchers.IO) {
        // --- L0: accessibility tree ---
        val root = WayloAccessibilityService.instance?.rootInActiveWindow
        if (root != null) {
            val hit = ElementFinder.findElement(root, step, targetPackage, screenWidth, screenHeight)
            if (hit != null) {
                Log.e("WAYLO_DOT", "Pipeline L0(semantic) hit at ${hit.first},${hit.second}")
                return@withContext PipelineResult(
                    x = hit.first, y = hit.second,
                    source = "accessibility", confidence = 100f, label = step.findDescription
                )
            }
        } else {
            Log.w(TAG, "Pipeline L0: no active window root.")
        }

        // --- L1: screen capture + OCR, then L2: YOLOv8 on the same frame ---
        val bitmap = captureScreenSuspend(context)
        if (bitmap != null) {
            try {
                val ocrHit = com.waylo.ocr.OcrAnalyzer.findElement(bitmap, step, screenWidth, screenHeight)
                if (ocrHit != null) {
                    Log.e("WAYLO_DOT", "Pipeline L1(semantic OCR) hit at ${ocrHit.first},${ocrHit.second}")
                    return@withContext PipelineResult(
                        x = ocrHit.first, y = ocrHit.second,
                        source = "ocr", confidence = 60f, label = step.findDescription
                    )
                }

                // L2: on-device YOLOv8-nano (icon-only / custom UI elements).
                val yolo = yoloDetector(context)
                if (yolo != null) {
                    val yoloHit = yolo.findBest(bitmap, step, screenWidth, screenHeight)
                    if (yoloHit != null) {
                        Log.e("WAYLO_DOT", "Pipeline L2(YOLO) hit at ${yoloHit.first},${yoloHit.second}")
                        return@withContext PipelineResult(
                            x = yoloHit.first, y = yoloHit.second,
                            source = "yolo", confidence = 50f, label = step.findDescription
                        )
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Pipeline L1/L2 threw.", e)
            } finally {
                if (!bitmap.isRecycled) bitmap.recycle()
            }
        } else {
            Log.e("WAYLO_DOT", "Pipeline L1/L2: capture returned null.")
        }

        Log.e("WAYLO_DOT", "Pipeline (L0+L1+L2) failed for: ${step.findDescription}")
        PipelineResult(0, 0, "failed", 0f, step.findDescription)
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
