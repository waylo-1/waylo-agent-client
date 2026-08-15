package com.waylo.guidance

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Covers GuidanceEngine.stepDisplayNumber(), the 0-based-array-index ->
 * 1-based-human-number conversion used consistently in step-related log
 * lines (including advanceFrom's, after a real on-device capture showed
 * "advanceFrom(2): verified, advancing to step 4" being misread as step 3
 * having been skipped — it hadn't; index 2 IS step 3, and advanceFrom's own
 * executeStep(index + 1) call always advances the array by exactly one
 * position). These tests lock in that numbering contract so it can't
 * silently drift back into an ambiguous log line.
 */
class GuidanceEngineStepNumberingTest {

    @Test
    fun `array index 0 is step 1`() {
        assertEquals(1, GuidanceEngine.stepDisplayNumber(0))
    }

    @Test
    fun `array index 2 is step 3, matching the real capture that looked like a skip`() {
        assertEquals(3, GuidanceEngine.stepDisplayNumber(2))
    }

    @Test
    fun `the next array position after index 2 is step 4 with no gap`() {
        // This is the exact pair from the on-device log: advanceFrom(2)
        // (step 3 verified) advances to array index 3 (step 4) — consecutive
        // array positions, consecutive step numbers, nothing skipped.
        val justVerified = GuidanceEngine.stepDisplayNumber(2)
        val next = GuidanceEngine.stepDisplayNumber(2 + 1)
        assertEquals(3, justVerified)
        assertEquals(4, next)
        assertEquals("advancing by one array position always advances the display number by exactly one", 1, next - justVerified)
    }

    @Test
    fun `advancing by one array position always advances the display number by exactly one`() {
        for (arrayIndex in 0..20) {
            val current = GuidanceEngine.stepDisplayNumber(arrayIndex)
            val next = GuidanceEngine.stepDisplayNumber(arrayIndex + 1)
            assertEquals(1, next - current)
        }
    }
}
