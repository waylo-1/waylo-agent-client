package com.waylo.guidance

import com.waylo.ai.Step
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Covers three fixes from a real on-device run:
 *
 * BUG 1 — the app was speaking `Step.findDescription` (the matcher's own
 * long, hedge-y search text — "SPOKE_DESCRIPTION | whichFieldUsed=findDescription"
 * on every step) instead of the short, user-facing `Step.instruction`.
 * [GuidanceEngine.targetDescriptionMessage] is now the one place that
 * decides what gets spoken, and it must always return `instruction`.
 *
 * BUG 2 — spoken nudges repeated over TEXT_INPUT/app-open/swipe steps while
 * the user was mid-action. [GuidanceEngine.isActionStepNoRepeat] is the
 * predicate that suppresses those nudges for exactly those step types.
 *
 * BUG 3 — the mic overlay never dismissed and could be triggered while an
 * IME was up. [GuidanceEngine.isImePackage] is the package-name heuristic
 * behind that suppression (see also [GuidanceEngine.shouldSuppressCorrectionPrompt],
 * which composes this with live state and isn't unit-testable the same way).
 */
class GuidanceEngineSpeechMicTest {

    private fun step(instruction: String, findDescription: String) = Step(
        index = 1,
        instruction = instruction,
        findDescription = findDescription
    )

    // --- BUG 1: spoken message is always instruction, never findDescription ---

    @Test
    fun `spoken message is the instruction field, not findDescription`() {
        val s = step(
            instruction = "Tap the History button.",
            findDescription = "history icon or library tab, maybe a clock-rewind icon, sideways placement possible"
        )
        val message = GuidanceEngine.targetDescriptionMessage(s)
        assertEquals("Tap the History button.", message)
        assertNotEquals(s.findDescription, message)
    }

    @Test
    fun `spoken message never contains matcher hedge words from findDescription`() {
        // Directly reproduces the reported symptom: findDescription full of
        // "or"/"maybe"/alternative wording that must never reach speech.
        val s = step(
            instruction = "Tap Settings.",
            findDescription = "gear icon or three dots menu, maybe top right, could be sideways on tablets"
        )
        val message = GuidanceEngine.targetDescriptionMessage(s)
        assertFalse(message.contains("maybe"))
        assertFalse(message.contains(" or "))
        assertFalse(message.contains("sideways"))
        assertEquals(s.instruction, message)
    }

    @Test
    fun `spoken message is instruction verbatim even when instruction and findDescription happen to share words`() {
        val s = step(instruction = "Tap History.", findDescription = "History")
        assertEquals("Tap History.", GuidanceEngine.targetDescriptionMessage(s))
    }

    // --- BUG 2: action steps (TEXT_INPUT / AppLaunch / implied scroll) never repeat ---

    @Test
    fun `suppresses repeat for a TEXT_INPUT step`() {
        assertTrue(GuidanceEngine.isActionStepNoRepeat(isTextInput = true, isAppLaunch = false, impliesScroll = false))
    }

    @Test
    fun `suppresses repeat for an AppLaunch (app-open) step`() {
        assertTrue(GuidanceEngine.isActionStepNoRepeat(isTextInput = false, isAppLaunch = true, impliesScroll = false))
    }

    @Test
    fun `suppresses repeat for a step implying a scroll or swipe gesture`() {
        assertTrue(GuidanceEngine.isActionStepNoRepeat(isTextInput = false, isAppLaunch = false, impliesScroll = true))
    }

    @Test
    fun `does not suppress a plain tap-in-app step`() {
        assertFalse(GuidanceEngine.isActionStepNoRepeat(isTextInput = false, isAppLaunch = false, impliesScroll = false))
    }

    // --- BUG 3: IME package detection ---

    @Test
    fun `flags known IME packages`() {
        assertTrue(GuidanceEngine.isImePackage("com.google.android.inputmethod.latin"))
        assertTrue(GuidanceEngine.isImePackage("com.touchtype.swiftkey"))
        assertTrue(GuidanceEngine.isImePackage("com.samsung.android.honeyboard"))
    }

    @Test
    fun `flags OEM IME variants by substring`() {
        assertTrue(GuidanceEngine.isImePackage("com.oem.inputmethod.custom"))
    }

    @Test
    fun `does not flag a real target app`() {
        assertFalse(GuidanceEngine.isImePackage("com.google.android.youtube"))
    }

    @Test
    fun `does not flag other transient (non-IME) packages`() {
        // Screen recorders/system dialogs are transient too, but not IME —
        // isImePackage must not conflate the two.
        assertFalse(GuidanceEngine.isImePackage("com.android.systemui"))
        assertFalse(GuidanceEngine.isImePackage("com.oplus.screenrecorder"))
    }
}
