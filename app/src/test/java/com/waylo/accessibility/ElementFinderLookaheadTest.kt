package com.waylo.accessibility

import android.view.accessibility.AccessibilityNodeInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.mockito.Mockito.mock
import org.mockito.Mockito.`when`

/**
 * Covers the lookahead-skip (screen-aware step skipping) and lowered-
 * confidence partial-match scoring added to ElementFinder for
 * GuidanceEngine. Both are pure functions over a supplied node snapshot (no
 * live AccessibilityService needed), mirroring the existing scoreNode() test
 * seam in ElementFinderTest.
 */
class ElementFinderLookaheadTest {

    private fun node(
        contentDescription: String? = null,
        text: String? = null,
        viewId: String? = null,
        clickable: Boolean = false,
        visible: Boolean = false
    ): AccessibilityNodeInfo {
        val n = mock(AccessibilityNodeInfo::class.java)
        `when`(n.contentDescription).thenReturn(contentDescription)
        `when`(n.text).thenReturn(text)
        `when`(n.viewIdResourceName).thenReturn(viewId)
        `when`(n.isClickable).thenReturn(clickable)
        `when`(n.isVisibleToUser).thenReturn(visible)
        return n
    }

    // --- scoreMultiple (lookahead skip) ---

    @Test
    fun `finds a confident match for a later step while current step's target is absent`() {
        val historyNode = node(text = "History", clickable = true, visible = true)
        val distractor = node(text = "Settings", clickable = true, visible = true)
        val allNodes = listOf(historyNode, distractor)

        val queries = listOf(
            ElementFinder.ElementQuery("account button top right"), // current step — nothing on screen matches
            ElementFinder.ElementQuery("history tab in library")     // step N+2 — "History" is directly visible
        )

        val results = ElementFinder.scoreMultiple(allNodes, queries)

        assertEquals(2, results.size)
        assertNull("current step's target genuinely isn't present", results[0])
        assertNotNull("later step's target is directly on screen", results[1])
        assertTrue(results[1]!!.isConfident())
        assertEquals(historyNode, results[1]!!.node)
    }

    @Test
    fun `never fabricates a match when nothing qualifies`() {
        val allNodes = listOf(node(text = "Home", clickable = true, visible = true))
        val queries = listOf(ElementFinder.ElementQuery("checkout payment card number"))

        val results = ElementFinder.scoreMultiple(allNodes, queries)

        assertEquals(1, results.size)
        assertNull(results[0])
    }

    @Test
    fun `scores each query independently against the same node snapshot`() {
        val historyNode = node(text = "History", clickable = true, visible = true)
        val settingsNode = node(text = "Settings", clickable = true, visible = true)
        val allNodes = listOf(historyNode, settingsNode)

        val results = ElementFinder.scoreMultiple(
            allNodes,
            listOf(
                ElementFinder.ElementQuery("history tab"),
                ElementFinder.ElementQuery("settings gear")
            )
        )

        assertEquals(historyNode, results[0]!!.node)
        assertEquals(settingsNode, results[1]!!.node)
    }

    @Test
    fun `returns empty list for empty queries`() {
        val allNodes = listOf(node(text = "Home"))
        assertTrue(ElementFinder.scoreMultiple(allNodes, emptyList()).isEmpty())
    }

    // --- scorePartialMatch (lowered-confidence acceptance) ---

    @Test
    fun `accepts a strong alternateLabels hit the primary description missed`() {
        val target = node(text = "History", clickable = true, visible = true)
        val distractor = node(text = "Settings", clickable = true, visible = true)
        val allNodes = listOf(target, distractor)

        val match = ElementFinder.scorePartialMatch(
            allNodes,
            alternateLabels = listOf("History", "Watch history"),
            visualDescription = "clock icon with history label"
        )

        assertNotNull(match)
        assertEquals(target, match!!.node)
    }

    @Test
    fun `refuses to accept pure affordance noise with no real signal`() {
        // Clickable + visible only — no text/desc/alternateLabel/visualDescription signal at all.
        val allNodes = listOf(node(clickable = true, visible = true))

        val match = ElementFinder.scorePartialMatch(
            allNodes,
            alternateLabels = emptyList(),
            visualDescription = null
        )

        assertNull(match)
    }

    @Test
    fun `returns null when there are no words to search with`() {
        val allNodes = listOf(node(text = "History", clickable = true, visible = true))
        val match = ElementFinder.scorePartialMatch(allNodes, emptyList(), null)
        assertNull(match)
    }

    @Test
    fun `accepts even when the confidence gap would fail isConfident`() {
        // Two near-identical "History" nodes — ambiguous by isConfident()'s
        // gap rule, but scorePartialMatch intentionally skips that check
        // since it's only reached as a last resort after the primary search
        // already failed for the step's entire patient window.
        val first = node(text = "History", clickable = true, visible = true)
        val second = node(text = "History", clickable = true, visible = true)
        val allNodes = listOf(first, second)

        val match = ElementFinder.scorePartialMatch(
            allNodes,
            alternateLabels = listOf("History"),
            visualDescription = null
        )

        assertNotNull(match)
        assertTrue("score clears the confident bar", match!!.score >= 35)
        assertEquals("tied with the runner-up", 0, match.score - match.runnerUpScore)
        assertTrue("this is exactly the case isConfident() would reject", !match.isConfident())
    }

    @Test
    fun `visualDescription words alone are enough without alternateLabels`() {
        val target = node(contentDescription = "clock rewind icon", clickable = true, visible = true)
        val allNodes = listOf(target)

        val match = ElementFinder.scorePartialMatch(
            allNodes,
            alternateLabels = emptyList(),
            visualDescription = "a small clock with a rewind arrow"
        )

        assertNotNull(match)
        assertEquals(target, match!!.node)
    }
}
