package com.waylo.ocr

import android.graphics.Bitmap
import android.graphics.Rect
import android.util.Log
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizer
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.coroutines.suspendCoroutine

/**
 * A single block of text detected on screen by ML Kit, with its location.
 */
data class OcrElement(
    val text: String,
    val boundingBox: Rect,
    val confidence: Float,
    val centerX: Int,
    val centerY: Int
)

/**
 * On-device OCR using ML Kit Latin text recognition. This is Layer 2 of the
 * guidance pipeline — it reads the visual screen when the accessibility tree
 * search is not confident enough.
 */
object OcrAnalyzer {

    private const val TAG = "Waylo"

    private val recognizer: TextRecognizer by lazy {
        TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
    }

    /**
     * Run text recognition over [bitmap] and return every detected text block.
     */
    suspend fun analyzeScreen(bitmap: Bitmap): List<OcrElement> =
        suspendCoroutine { continuation ->
            val image = InputImage.fromBitmap(bitmap, 0)
            recognizer.process(image)
                .addOnSuccessListener { result ->
                    val elements = mutableListOf<OcrElement>()
                    for (block in result.textBlocks) {
                        for (line in block.lines) {
                            val box = line.boundingBox ?: continue
                            // ML Kit Latin recognizer exposes line confidence
                            // as a primitive float; default to 1.0 if it is NaN.
                            val rawConfidence = line.confidence
                            val confidence = if (rawConfidence.isNaN()) 1.0f else rawConfidence
                            val element = OcrElement(
                                text = line.text,
                                boundingBox = box,
                                confidence = confidence,
                                centerX = box.centerX(),
                                centerY = box.centerY()
                            )
                            elements.add(element)
                            Log.d(
                                TAG,
                                "OCR block: '${element.text}' box=$box " +
                                    "confidence=${"%.2f".format(confidence)} " +
                                    "center=(${element.centerX},${element.centerY})"
                            )
                        }
                    }
                    Log.d(TAG, "OCR detected ${elements.size} text lines.")
                    continuation.resume(elements)
                }
                .addOnFailureListener { e ->
                    Log.e(TAG, "OCR recognition failed.", e)
                    continuation.resumeWithException(e)
                }
        }

    /**
     * Find the best OCR element matching [description]. If [visualDescription]
     * is supplied (backend's free-text look of the element), its words are
     * folded into the per-word token pass too — small additive help only, the
     * exact/partial match on [description] still drives the bulk of the score.
     * Scoring: exact match +60, partial (substring) +35, per word match +15.
     * Returns the highest scorer if it has any positive score, else null.
     */
    fun findBestMatch(
        elements: List<OcrElement>,
        description: String,
        visualDescription: String? = null
    ): OcrElement? {
        if (elements.isEmpty()) return null
        val desc = description.lowercase().trim()
        val tokens = desc.split(Regex("\\s+")).filter { it.isNotBlank() }.toMutableList()
        if (!visualDescription.isNullOrBlank()) {
            tokens += visualDescription.lowercase().trim()
                .split(Regex("\\s+"))
                .filter { it.length > 2 }
        }

        var best: OcrElement? = null
        var bestScore = 0

        for (element in elements) {
            val text = element.text.lowercase().trim()
            var score = 0
            if (text == desc) {
                score += 60
            } else if (text.contains(desc) || desc.contains(text)) {
                score += 35
            }
            for (token in tokens) {
                if (text.contains(token)) score += 15
            }

            if (score > bestScore) {
                bestScore = score
                best = element
            }
        }

        return if (best != null && bestScore > 0) {
            Log.d(TAG, "OCR best match: '${best.text}' score=$bestScore center=(${best.centerX},${best.centerY})")
            best
        } else {
            Log.d(TAG, "OCR found no match for '$description'.")
            null
        }
    }

    /** Release the recognizer's native resources. */
    fun close() {
        recognizer.close()
    }
}
