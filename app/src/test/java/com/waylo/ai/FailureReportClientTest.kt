package com.waylo.ai

import android.graphics.Rect
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Covers FailureReportClient's payload-building (CorrectedTarget.toJson()/
 * ChosenBox.toJson()) against the backend's actual routes/failure.js field
 * names (bounds/text/contentDescription/viewId for corrected_target;
 * centerX/centerY/confidence/source/ax_class for chosen_box) — these are the
 * exact keys the route destructures, so a mismatch here would silently drop
 * data server-side rather than error.
 */
class FailureReportClientTest {

    @Test
    fun `CorrectedTarget serializes all fields with the names the backend expects`() {
        val target = FailureReportClient.CorrectedTarget(
            // The Android stub jar's Rect(l,t,r,b) constructor is a no-op in
            // plain JVM unit tests (fields stay 0) — direct field assignment
            // on the no-arg constructor bypasses that (real field writes,
            // not a stubbed method body).
            bounds = Rect().apply { left = 10; top = 20; right = 110; bottom = 220 },
            text = "History",
            contentDescription = "History menu item",
            viewId = "com.google.android.youtube:id/title"
        )

        val json = with(FailureReportClient) { target.toJson() }

        val bounds = json.getJSONObject("bounds")
        assertEquals(10, bounds.getInt("left"))
        assertEquals(20, bounds.getInt("top"))
        assertEquals(110, bounds.getInt("right"))
        assertEquals(220, bounds.getInt("bottom"))
        assertEquals("History", json.getString("text"))
        assertEquals("History menu item", json.getString("contentDescription"))
        assertEquals("com.google.android.youtube:id/title", json.getString("viewId"))
    }

    @Test
    fun `CorrectedTarget omits absent fields rather than writing nulls`() {
        val target = FailureReportClient.CorrectedTarget(
            bounds = null,
            text = null,
            contentDescription = "History menu item",
            viewId = null
        )

        val json = with(FailureReportClient) { target.toJson() }

        assertFalse(json.has("bounds"))
        assertFalse(json.has("text"))
        assertTrue(json.has("contentDescription"))
        assertFalse(json.has("viewId"))
    }

    @Test
    fun `ChosenBox serializes all fields with the names the backend expects`() {
        val box = FailureReportClient.ChosenBox(
            centerX = 215,
            centerY = 192,
            confidence = 0.87f,
            source = "omni",
            axClass = "icon"
        )

        val json = with(FailureReportClient) { box.toJson() }

        assertEquals(215, json.getInt("centerX"))
        assertEquals(192, json.getInt("centerY"))
        assertEquals(0.87, json.getDouble("confidence"), 0.001)
        assertEquals("omni", json.getString("source"))
        assertEquals("icon", json.getString("ax_class"))
    }

    @Test
    fun `ChosenBox omits absent source and ax_class`() {
        val box = FailureReportClient.ChosenBox(
            centerX = 1,
            centerY = 2,
            confidence = 0.6f,
            source = null,
            axClass = null
        )

        val json = with(FailureReportClient) { box.toJson() }

        assertFalse(json.has("source"))
        assertFalse(json.has("ax_class"))
    }
}
