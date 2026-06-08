package com.sahayak.accessibility

import android.graphics.Rect
import android.util.Log
import android.view.accessibility.AccessibilityNodeInfo

/**
 * Scoring-based search over the live accessibility tree (Layer 1 of the guidance
 * fallback chain). Instant and fully on-device.
 *
 * Given an English [findDescription] like "plus button create post bottom nav",
 * it tokenises the description and scores every node on screen, returning the best
 * candidate if it clears a confidence threshold.
 */
object ElementFinder {

    private const val TAG = "Sahayak"

    /** Minimum score required for a match to be considered reliable. */
    private const val MIN_SCORE = 30

    data class MatchResult(
        val node: AccessibilityNodeInfo,
        val score: Int,
        val matchReason: String
    )

    /**
     * Find the best on-screen element matching [description].
     * Returns null if no node clears [MIN_SCORE] or the service is not connected.
     */
    fun findElement(description: String): MatchResult? {
        val service = SahayakAccessibilityService.instance
        if (service == null) {
            Log.d(TAG, "ElementFinder: accessibility service not connected.")
            return null
        }

        val nodes = service.getAllNodes()
        if (nodes.isEmpty()) {
            Log.d(TAG, "ElementFinder: no nodes on screen.")
            return null
        }

        val scored = nodes
            .map { node -> MatchResult(node, scoreNode(node, description), buildReason(node, description)) }
            .sortedByDescending { it.score }

        // Log the top 3 candidates for debugging.
        scored.take(3).forEachIndexed { i, m ->
            Log.d(
                TAG,
                "Candidate #${i + 1}: score=${m.score} " +
                    "text='${m.node.text}' desc='${m.node.contentDescription}' " +
                    "id='${m.node.viewIdResourceName}' reason=${m.matchReason}"
            )
        }

        val best = scored.firstOrNull()
        return if (best != null && best.score > MIN_SCORE) {
            Log.d(TAG, "ElementFinder: matched with score ${best.score}.")
            best
        } else {
            Log.d(TAG, "ElementFinder: no node cleared threshold ($MIN_SCORE).")
            null
        }
    }

    /**
     * Score a single node against the description using a set of weighted rules.
     * Higher is better.
     */
    fun scoreNode(node: AccessibilityNodeInfo, description: String): Int {
        var score = 0
        val desc = description.lowercase().trim()
        val tokens = desc.split(Regex("\\s+")).filter { it.isNotBlank() }

        val contentDesc = node.contentDescription?.toString()?.lowercase()?.trim()
        val text = node.text?.toString()?.lowercase()?.trim()
        val viewId = node.viewIdResourceName?.substringAfterLast('/')?.lowercase()?.trim()

        // contentDescription matching
        if (!contentDesc.isNullOrBlank()) {
            if (contentDesc == desc) {
                score += 60
            } else if (contentDesc.contains(desc) || desc.contains(contentDesc)) {
                score += 40
            }
        }

        // text matching
        if (!text.isNullOrBlank()) {
            if (text == desc) {
                score += 50
            } else if (text.contains(desc) || desc.contains(text)) {
                score += 30
            }
        }

        // viewId (last segment) matching
        if (!viewId.isNullOrBlank()) {
            if (tokens.any { viewId.contains(it) } || desc.contains(viewId)) {
                score += 35
            }
        }

        // affordance bonuses
        if (node.isClickable) score += 15
        if (node.isVisibleToUser) score += 10

        // per-word presence across any field (cumulative)
        for (token in tokens) {
            val inDesc = contentDesc?.contains(token) == true
            val inText = text?.contains(token) == true
            val inId = viewId?.contains(token) == true
            if (inDesc || inText || inId) {
                score += 10
            }
        }

        return score
    }

    /**
     * Bounds of a node in absolute screen coordinates.
     */
    fun getBoundsOnScreen(node: AccessibilityNodeInfo): Rect {
        val rect = Rect()
        node.getBoundsInScreen(rect)
        return rect
    }

    /** Human-readable explanation of why a node scored as it did (debug aid). */
    private fun buildReason(node: AccessibilityNodeInfo, description: String): String {
        val parts = mutableListOf<String>()
        val desc = description.lowercase().trim()
        val contentDesc = node.contentDescription?.toString()?.lowercase()?.trim()
        val text = node.text?.toString()?.lowercase()?.trim()
        if (contentDesc == desc) parts.add("exactDesc")
        else if (!contentDesc.isNullOrBlank() && (contentDesc.contains(desc) || desc.contains(contentDesc))) parts.add("partialDesc")
        if (text == desc) parts.add("exactText")
        else if (!text.isNullOrBlank() && (text.contains(desc) || desc.contains(text))) parts.add("partialText")
        if (node.isClickable) parts.add("clickable")
        if (node.isVisibleToUser) parts.add("visible")
        return if (parts.isEmpty()) "weak" else parts.joinToString("+")
    }
}
