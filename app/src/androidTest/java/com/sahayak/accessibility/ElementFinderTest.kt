package com.sahayak.accessibility

import android.view.accessibility.AccessibilityNodeInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.mockito.Mockito.mock
import org.mockito.Mockito.`when`
import androidx.test.ext.junit.runners.AndroidJUnit4

/**
 * Verifies the scoring logic in [ElementFinder.scoreNode]. We mock
 * AccessibilityNodeInfo objects (the real class can't be instantiated directly)
 * and assert that the expected candidate scores highest.
 */
@RunWith(AndroidJUnit4::class)
class ElementFinderTest {

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

    @Test
    fun exactContentDescriptionScoresHigh() {
        val n = node(contentDescription = "plus button", clickable = true, visible = true)
        val score = ElementFinder.scoreNode(n, "plus button")
        // 60 (exact desc) + 15 (clickable) + 10 (visible) + 20 (two word matches)
        assertEquals(105, score)
    }

    @Test
    fun exactTextScoresHigherThanPartial() {
        val exact = node(text = "create")
        val partial = node(text = "create post here")
        val exactScore = ElementFinder.scoreNode(exact, "create")
        val partialScore = ElementFinder.scoreNode(partial, "create")
        assertTrue("exact text should outscore partial", exactScore > partialScore)
    }

    @Test
    fun viewIdSegmentContributesToScore() {
        val n = node(viewId = "com.instagram.android:id/tab_avatar")
        val score = ElementFinder.scoreNode(n, "avatar")
        // 35 (viewId token match) + 10 (word presence)
        assertEquals(45, score)
    }

    @Test
    fun bestCandidateOutscoresWeakOnes() {
        val target = node(
            contentDescription = "plus button create post",
            viewId = "com.instagram.android:id/create_tab",
            clickable = true,
            visible = true
        )
        val distractor = node(text = "Home", visible = true)
        val description = "plus button create post bottom nav"

        val targetScore = ElementFinder.scoreNode(target, description)
        val distractorScore = ElementFinder.scoreNode(distractor, description)

        assertTrue(
            "intended target ($targetScore) must beat distractor ($distractorScore)",
            targetScore > distractorScore
        )
        assertTrue("target should clear threshold", targetScore > 30)
    }
}
