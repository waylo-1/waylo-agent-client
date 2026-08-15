package com.waylo.guidance

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Covers GuidanceEngine.shouldContinuePeriodicRescan() — the pure stop
 * condition behind periodicRescan() (BUG A's fix: an active, tighter-cadence
 * rescan that runs alongside the event-driven locate loop so an already-
 * visible target gets found without needing a manual screen change first).
 * Locks in the exact "start while waiting for the target, stop as soon as
 * it's found / the step changes / guidance stops" contract described in the
 * task, independent of the coroutine/Android entanglement the real loop
 * lives in.
 */
class GuidanceEnginePeriodicRescanTest {

    @Test
    fun `continues while running, on the current step, and still locating`() {
        assertTrue(GuidanceEngine.shouldContinuePeriodicRescan(isRunning = true, isCurrentStep = true, isLocating = true))
    }

    @Test
    fun `stops once guidance is no longer running`() {
        assertFalse(GuidanceEngine.shouldContinuePeriodicRescan(isRunning = false, isCurrentStep = true, isLocating = true))
    }

    @Test
    fun `stops once the step has advanced (no longer the current step)`() {
        // e.g. the step this rescan was launched for was verified/advanced
        // past, or a lookahead skip jumped to a different step.
        assertFalse(GuidanceEngine.shouldContinuePeriodicRescan(isRunning = true, isCurrentStep = false, isLocating = true))
    }

    @Test
    fun `stops once the target is found and the dot is placed (phase leaves LOCATING)`() {
        assertFalse(GuidanceEngine.shouldContinuePeriodicRescan(isRunning = true, isCurrentStep = true, isLocating = false))
    }

    @Test
    fun `stops when everything has gone wrong at once`() {
        assertFalse(GuidanceEngine.shouldContinuePeriodicRescan(isRunning = false, isCurrentStep = false, isLocating = false))
    }
}
