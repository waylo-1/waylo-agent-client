package com.waylo.ai

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Covers the confidence floor + runner-up gap in
 * [YoloDetectionClient.selectBest], mirroring
 * [com.waylo.accessibility.ElementFinder]'s own isConfident() gate. The dot
 * must never be placed on an ambiguous, near-tied detection.
 */
class YoloDetectionClientTest {

    private fun detection(confidence: Float, x: Int = 0) =
        YoloDetectionClient.Detection(centerX = x, centerY = 0, confidence = confidence)

    @Test
    fun `accepts a single confident detection with no competitors`() {
        val result = YoloDetectionClient.selectBest(listOf(detection(0.8f)))
        assertEquals(0.8f, result?.confidence)
    }

    @Test
    fun `rejects a confident-looking top detection with a near-tied runner-up`() {
        // Both clear MIN_CONFIDENCE (0.5) individually, but the gap between
        // them (0.05) is under MIN_CONFIDENCE_GAP (0.1) -- an ambiguous pick
        // between the real target and a visually similar icon.
        val elements = listOf(detection(0.6f, x = 100), detection(0.55f, x = 400))
        assertNull(YoloDetectionClient.selectBest(elements))
    }

    @Test
    fun `accepts a clear leader with a real gap over the runner-up`() {
        val elements = listOf(detection(0.9f, x = 100), detection(0.55f, x = 400))
        val result = YoloDetectionClient.selectBest(elements)
        assertEquals(100, result?.centerX)
    }

    @Test
    fun `rejects when the top detection is below the absolute floor even with a clear gap`() {
        val elements = listOf(detection(0.3f), detection(0.05f))
        assertNull(YoloDetectionClient.selectBest(elements))
    }

    @Test
    fun `returns null for an empty detection list`() {
        assertNull(YoloDetectionClient.selectBest(emptyList()))
    }
}
