package com.waylo.guidance

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Covers GuidanceEngine.shouldAllowNotFoundNudge() — the pure interval check
 * behind the BUG-B fix: the "target not found" description/hint speech must
 * fire at most once, then stay silent until a longer nudge interval passes,
 * instead of repeating on every patient-window escalation (previously as
 * often as every 6s for image-only targets).
 */
class GuidanceEngineNotFoundNudgeTest {

    @Test
    fun `allows the very first nudge (never spoken this step)`() {
        // lastNudgeAtMs=0L is GuidanceEngine's own "never spoken yet" sentinel.
        assertTrue(GuidanceEngine.shouldAllowNotFoundNudge(nowMs = 20_000L, lastNudgeAtMs = 0L, minIntervalMs = 15_000L))
    }

    @Test
    fun `suppresses a repeat well inside the interval`() {
        // Mirrors the reported bug: an image-only target's 6s patient window
        // hitting the escalation branch repeatedly.
        assertFalse(GuidanceEngine.shouldAllowNotFoundNudge(nowMs = 12_000L, lastNudgeAtMs = 6_000L, minIntervalMs = 15_000L))
    }

    @Test
    fun `suppresses right up to just under the interval`() {
        assertFalse(GuidanceEngine.shouldAllowNotFoundNudge(nowMs = 20_999L, lastNudgeAtMs = 6_000L, minIntervalMs = 15_000L))
    }

    @Test
    fun `allows exactly at the interval boundary`() {
        assertTrue(GuidanceEngine.shouldAllowNotFoundNudge(nowMs = 21_000L, lastNudgeAtMs = 6_000L, minIntervalMs = 15_000L))
    }

    @Test
    fun `allows well past the interval`() {
        assertTrue(GuidanceEngine.shouldAllowNotFoundNudge(nowMs = 50_000L, lastNudgeAtMs = 6_000L, minIntervalMs = 15_000L))
    }
}
