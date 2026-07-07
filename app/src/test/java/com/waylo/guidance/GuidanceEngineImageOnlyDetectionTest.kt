package com.waylo.guidance

import com.waylo.ai.Step
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Covers GuidanceEngine.looksLikeImageOnlyTarget(), which flags steps whose
 * target is likely an image-only element (e.g. a round profile picture)
 * with no text/contentDescription the tree/OCR layers can ever confidently
 * match — such steps get a much shorter patient window before escalating to
 * partial-match/YOLO/vision instead of waiting the full 30s timeout.
 */
class GuidanceEngineImageOnlyDetectionTest {

    private fun step(elementType: String?, visualDescription: String?) = Step(
        index = 1,
        instruction = "Look for the red dot on your round profile picture and tap it.",
        findDescription = "profile picture",
        elementType = elementType,
        visualDescription = visualDescription
    )

    @Test
    fun `flags an ICON_BUTTON with a picture-like visualDescription`() {
        val s = step("ICON_BUTTON", "round picture button near the top of the screen")
        assertTrue(GuidanceEngine.looksLikeImageOnlyTarget(s))
    }

    @Test
    fun `flags an IMAGE type with an avatar-like visualDescription`() {
        val s = step("IMAGE", "small round avatar icon")
        assertTrue(GuidanceEngine.looksLikeImageOnlyTarget(s))
    }

    @Test
    fun `is case-insensitive on elementType`() {
        val s = step("icon_button", "profile photo thumbnail")
        assertTrue(GuidanceEngine.looksLikeImageOnlyTarget(s))
    }

    @Test
    fun `does not flag a LIST_ITEM even with a picture-like visualDescription`() {
        val s = step("LIST_ITEM", "text that says History next to a small picture icon")
        assertFalse(GuidanceEngine.looksLikeImageOnlyTarget(s))
    }

    @Test
    fun `does not flag an ICON_BUTTON with a non-picture visualDescription`() {
        val s = step("ICON_BUTTON", "circle with three horizontal lines inside")
        assertFalse(GuidanceEngine.looksLikeImageOnlyTarget(s))
    }

    @Test
    fun `does not flag a step with no elementType at all`() {
        val s = step(null, "round picture button near the top of the screen")
        assertFalse(GuidanceEngine.looksLikeImageOnlyTarget(s))
    }

    @Test
    fun `does not flag a step with no visualDescription at all`() {
        val s = step("ICON_BUTTON", null)
        assertFalse(GuidanceEngine.looksLikeImageOnlyTarget(s))
    }
}
