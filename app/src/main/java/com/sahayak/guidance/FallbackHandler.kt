// TODO: Day 15-16 — implement the Layer 2 (ML Kit OCR) and Layer 3 (Gemini Vision)
// fallbacks used when ElementFinder fails to locate an element.
package com.sahayak.guidance

import com.sahayak.ai.Step

/**
 * Fallback chain for when the accessibility-tree search (Layer 1) fails.
 *
 *  - Layer 2: ML Kit on-device OCR over a screenshot.
 *  - Layer 3: Gemini Vision API via the backend.
 */
object FallbackHandler {

    /** TODO: Day 15 — run ML Kit OCR over a screenshot to locate the element. */
    suspend fun tryOcr(step: Step): Boolean {
        // TODO
        return false
    }

    /** TODO: Day 16 — send the screenshot to Gemini Vision for guidance. */
    suspend fun tryVision(step: Step): Boolean {
        // TODO. Remember: never store screenshots — delete after the API call returns.
        return false
    }
}
