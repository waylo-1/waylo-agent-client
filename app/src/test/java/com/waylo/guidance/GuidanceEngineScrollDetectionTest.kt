package com.waylo.guidance

import com.waylo.ai.Step
import com.waylo.overlay.ArrowView
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Covers GuidanceEngine.impliedScrollDirection(), the pure keyword-detection
 * logic behind the scroll/swipe arrow overlay: steps whose instruction or
 * fallbackHint imply a gesture get a directional arrow instead of nothing
 * while their target is being searched for.
 */
class GuidanceEngineScrollDetectionTest {

    private fun step(instruction: String, fallbackHint: String? = null) = Step(
        index = 1,
        instruction = instruction,
        findDescription = "irrelevant for this test",
        fallbackHint = fallbackHint
    )

    @Test
    fun `detects swipe up in the instruction`() {
        val s = step("Swipe up from the bottom of the screen to see all your apps.")
        assertEquals(ArrowView.Direction.UP, GuidanceEngine.impliedScrollDirection(s))
    }

    @Test
    fun `detects scroll down in the instruction`() {
        val s = step("Scroll down to find the button.")
        assertEquals(ArrowView.Direction.DOWN, GuidanceEngine.impliedScrollDirection(s))
    }

    @Test
    fun `detects the gesture from fallbackHint when the instruction doesn't mention it`() {
        val s = step("Tap the History picture button.", fallbackHint = "if not visible, scroll down the settings menu")
        assertEquals(ArrowView.Direction.DOWN, GuidanceEngine.impliedScrollDirection(s))
    }

    @Test
    fun `returns null for a plain tap instruction with no gesture words`() {
        val s = step("Tap the Settings picture button.", fallbackHint = "if not visible, look near the top of the screen")
        assertNull(GuidanceEngine.impliedScrollDirection(s))
    }

    @Test
    fun `returns null when there is no direction word at all`() {
        val s = step("Swipe to reveal more options.")
        assertNull(GuidanceEngine.impliedScrollDirection(s))
    }

    @Test
    fun `is case-insensitive`() {
        val s = step("SWIPE UP from the bottom.")
        assertEquals(ArrowView.Direction.UP, GuidanceEngine.impliedScrollDirection(s))
    }

    @Test
    fun `does not match unrelated words containing up or down as a substring`() {
        // "group" contains "up" but not as a whole word; "shutdown" contains "down" similarly.
        val s = step("Tap the group icon to shutdown the session.")
        assertNull(GuidanceEngine.impliedScrollDirection(s))
    }
}
