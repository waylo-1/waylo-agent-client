package com.waylo.guidance

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Covers the priority fix: a confident element match must never be blocked
 * by the wrong-app/foreground-package guard — the guard only applies as a
 * FALLBACK once no confident match was found. Root cause from a real run
 * (step 2, target "History"): the accessibility tree found the target
 * confidently (score=130, gap=35) at 17:50:36, but the dot wasn't placed
 * until 17:50:44 — an 8s delay — because the wrong-app guard fired
 * repeatedly while the foreground package transiently read as
 * com.oplus.screenrecorder / com.android.systemui instead of
 * com.google.android.youtube.
 *
 * [GuidanceEngine.isTransientForegroundPackage] covers the source-level
 * fix (never let those packages overwrite the tracked foreground package
 * at all). This file covers the placement-priority fix directly: even if a
 * package mismatch reaches the guard, [GuidanceEngine.isInExpectedApp]
 * (unchanged) still correctly reports it as a mismatch — proving the guard
 * itself isn't broken — while [GuidanceEngine.isPlacementOverridingPackageMismatch]
 * (the real predicate both locateStep()'s and revalidatePlacement()'s fixed
 * scan loops use at the exact point they've already found a confident
 * match) confirms that mismatch is treated as an override to log, not a
 * block: "confident element found + wrong/transient package => dot still
 * placed."
 */
class GuidanceEngineWrongAppOverrideTest {

    private val youtube = "com.google.android.youtube"

    @Test
    fun `reproduces the reported mismatch - screen recorder overlay reads as foreground instead of YouTube`() {
        // This is the exact package from the real run's evidence.
        assertFalse(
            "the guard's own mismatch detection must still work correctly (it's still used as the fallback signal)",
            GuidanceEngine.isInExpectedApp(index = 2, foregroundPackage = "com.oplus.screenrecorder", expectedAppPackage = youtube)
        )
    }

    @Test
    fun `reproduces the reported mismatch - systemui overlay reads as foreground instead of YouTube`() {
        assertFalse(
            GuidanceEngine.isInExpectedApp(index = 2, foregroundPackage = "com.android.systemui", expectedAppPackage = youtube)
        )
    }

    @Test
    fun `confident element found plus wrong package - placement override predicate fires (dot still placed)`() {
        // Mirrors the exact reported scenario: step 2 confidently found
        // History (score=130) while lastKnownForegroundPackage had been
        // corrupted to com.oplus.screenrecorder. The fixed locateStep()/
        // revalidatePlacement() place the dot regardless (a confident
        // result always returns/continues before the package check is even
        // consulted) — this predicate is what they use to recognize and log
        // that override, proving the mismatch condition IS classified as
        // "override," not "block."
        assertTrue(
            GuidanceEngine.isPlacementOverridingPackageMismatch(index = 2, foregroundPackage = "com.oplus.screenrecorder", expectedAppPackage = youtube)
        )
    }

    @Test
    fun `confident element found plus a matching package - no override needed`() {
        assertFalse(
            GuidanceEngine.isPlacementOverridingPackageMismatch(index = 2, foregroundPackage = youtube, expectedAppPackage = youtube)
        )
    }

    @Test
    fun `confident element found plus unknown foreground signal - no override needed (fails open)`() {
        assertFalse(
            GuidanceEngine.isPlacementOverridingPackageMismatch(index = 2, foregroundPackage = null, expectedAppPackage = youtube)
        )
    }

    // --- isTransientForegroundPackage: the source-level fix ---

    @Test
    fun `flags the exact reported screen recorder package`() {
        assertTrue(GuidanceEngine.isTransientForegroundPackage("com.oplus.screenrecorder"))
    }

    @Test
    fun `flags systemui`() {
        assertTrue(GuidanceEngine.isTransientForegroundPackage("com.android.systemui"))
    }

    @Test
    fun `flags OEM screen recorder variants by substring`() {
        assertTrue(GuidanceEngine.isTransientForegroundPackage("com.samsung.android.screenrecorder"))
        assertTrue(GuidanceEngine.isTransientForegroundPackage("com.miui.screenrecord"))
    }

    @Test
    fun `flags known IME packages`() {
        assertTrue(GuidanceEngine.isTransientForegroundPackage("com.google.android.inputmethod.latin"))
        assertTrue(GuidanceEngine.isTransientForegroundPackage("com.touchtype.swiftkey"))
    }

    @Test
    fun `flags IME variants by substring`() {
        assertTrue(GuidanceEngine.isTransientForegroundPackage("com.oem.inputmethod.custom"))
    }

    @Test
    fun `flags permission dialog packages`() {
        assertTrue(GuidanceEngine.isTransientForegroundPackage("com.google.android.permissioncontroller"))
    }

    @Test
    fun `does not flag a real target app`() {
        assertFalse(GuidanceEngine.isTransientForegroundPackage(youtube))
        assertFalse(GuidanceEngine.isTransientForegroundPackage("com.whatsapp"))
    }

    @Test
    fun `does not flag an unrelated random package`() {
        assertFalse(GuidanceEngine.isTransientForegroundPackage("com.example.somegame"))
    }
}
