package com.waylo.ocr

import android.graphics.Rect
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Covers the confidence floor + runner-up gap added to
 * [OcrAnalyzer.findBestMatch], mirroring
 * [com.waylo.accessibility.ElementFinder]'s own isConfident() gate. The dot
 * must never be placed on an ambiguous, near-tied OCR match.
 */
class OcrAnalyzerTest {

    private fun element(text: String) = OcrElement(
        text = text,
        boundingBox = Rect(0, 0, 10, 10),
        confidence = 1.0f,
        centerX = 5,
        centerY = 5
    )

    @Test
    fun `accepts a clear exact match with no competing text`() {
        val elements = listOf(element("History"), element("Settings"))
        val match = OcrAnalyzer.findBestMatch(elements, "History")
        assertEquals("History", match?.text)
    }

    @Test
    fun `rejects a tie between two identical labels on screen`() {
        // Same label appears twice (e.g. a nav bar item and a list item below
        // it) — both score identically, so picking either would be a guess.
        val elements = listOf(element("History"), element("History"))
        val match = OcrAnalyzer.findBestMatch(elements, "History")
        assertNull(match)
    }

    @Test
    fun `accepts an exact match over a merely-partial competitor with a real gap`() {
        // "History" (exact +60, token hit +15 = 75) clearly outscores
        // "Watch History" (partial substring +35, token hit +15 = 50) --
        // a 25-point gap, well clear of the floor.
        val elements = listOf(element("History"), element("Watch History"))
        val match = OcrAnalyzer.findBestMatch(elements, "History")
        assertEquals("History", match?.text)
    }

    @Test
    fun `rejects pure noise below the score floor`() {
        val elements = listOf(element("Weather"), element("Photos"))
        val match = OcrAnalyzer.findBestMatch(elements, "History")
        assertNull(match)
    }

    @Test
    fun `returns null for an empty element list`() {
        assertNull(OcrAnalyzer.findBestMatch(emptyList(), "History"))
    }
}
