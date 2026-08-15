package com.waylo.ocr

import com.waylo.diagnostics.WayloVerify

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

    /**
     * A single ambiguous token match (score 15) is too weak to trust for
     * placing the dot — require at least a real partial/text match or a
     * couple of token hits, mirroring [com.waylo.accessibility.ElementFinder]'s
     * own confidence floor.
     */
    private const val MIN_MATCH_SCORE = 30

    /**
     * A confident top match must also clearly beat the runner-up by this
     * margin — mirrors [com.waylo.accessibility.ElementFinder.MIN_CONFIDENCE_GAP].
     * Same absolute value (10) is appropriate here too: unlike ElementFinder,
     * OCR has no affordance-derived baseline score (no clickable/visible
     * bonus) — an irrelevant text block scores exactly 0, so [MIN_MATCH_SCORE]
     * alone already screens out pure noise. What a score-only floor can't
     * catch is OCR's own specific failure mode: duplicate on-screen text
     * (e.g. the same label in both a nav bar and a list item below it)
     * scoring an exact or near-exact tie, where picking the numerically-first
     * one is an arbitrary guess, not a confident placement.
     */
    private const val MIN_MATCH_GAP = 10

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
     * If [alternateLabels] is supplied, each label that exactly or partially
     * matches a text block adds a further small bonus (mirrors the bonus
     * ElementFinder gives alternate labels over the accessibility tree).
     * Scoring: exact match +60, partial (substring) +35, per word match +15,
     * per alternate-label hit +15.
     * Returns the highest scorer only if it clears both [MIN_MATCH_SCORE] and
     * [MIN_MATCH_GAP] over the runner-up (see [MIN_MATCH_GAP]'s doc) — the
     * dot must never be placed on an ambiguous, near-tied match. Returns null
     * otherwise; the caller falls through to the next fallback layer, which
     * ultimately routes into GuidanceEngine's speakTargetDescription()+
     * re-scan path rather than ever guessing a position.
     */
    fun findBestMatch(
        elements: List<OcrElement>,
        description: String,
        visualDescription: String? = null,
        alternateLabels: List<String> = emptyList(),
        stepIndex: Int = -1
    ): OcrElement? {
        if (elements.isEmpty()) {
            WayloVerify.d("OCR_SCAN | stepIndex=$stepIndex | blockCount=0 | topScore=0 | topMatchedText= | " +
                    "runnerUpScore=0 | gap=0 | confident=false | failReason=no_candidates"
            )
            return null
        }
        val desc = description.lowercase().trim()
        val tokens = desc.split(Regex("\\s+")).filter { it.isNotBlank() }.toMutableList()
        if (!visualDescription.isNullOrBlank()) {
            tokens += visualDescription.lowercase().trim()
                .split(Regex("\\s+"))
                .filter { it.length > 2 }
        }
        val cleanedAlternates = alternateLabels.map { it.lowercase().trim() }.filter { it.isNotBlank() }

        val scored = elements.map { element ->
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
            var altHits = 0
            for (alt in cleanedAlternates) {
                if (text == alt || text.contains(alt)) altHits++
            }
            if (altHits > 0) score += altHits * 15
            element to score
        }.sortedByDescending { it.second }

        val best = scored.firstOrNull()
        val runnerUpScore = scored.getOrNull(1)?.second ?: 0
        val gap = (best?.second ?: 0) - runnerUpScore
        val confident = best != null && best.second >= MIN_MATCH_SCORE && gap >= MIN_MATCH_GAP
        val failReason = when {
            best == null -> "no_candidates"
            best.second < MIN_MATCH_SCORE -> "below_floor"
            gap < MIN_MATCH_GAP -> "gap_too_small"
            else -> "passed"
        }
        WayloVerify.d("OCR_SCAN | stepIndex=$stepIndex | blockCount=${elements.size} | topScore=${best?.second ?: 0} | " +
                "topMatchedText=${best?.first?.text?.take(80) ?: ""} | runnerUpScore=$runnerUpScore | gap=$gap | " +
                "confident=$confident | failReason=$failReason"
        )

        return if (confident) {
            Log.d(TAG, "OCR best match: '${best!!.first.text}' score=${best.second} runnerUp=$runnerUpScore center=(${best.first.centerX},${best.first.centerY})")
            best.first
        } else {
            Log.d(
                TAG,
                "OCR found no confident match for '$description' " +
                    "(best score ${best?.second ?: 0}, runnerUp=$runnerUpScore, floor=$MIN_MATCH_SCORE, gap=$MIN_MATCH_GAP)."
            )
            null
        }
    }

    /** Release the recognizer's native resources. */
    fun close() {
        recognizer.close()
    }
}
