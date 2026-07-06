package com.waylo.accessibility

import android.graphics.Rect
import android.util.Log
import android.view.accessibility.AccessibilityNodeInfo

/**
 * Scoring-based search over the live accessibility tree (Layer 1 of the guidance
 * fallback chain). Instant and fully on-device.
 *
 * Given an English [findElement] description like
 * "The YouTube app icon, which is a red rectangle with a white play button",
 * it strips filler/stop words, scores every node on screen against the
 * remaining meaningful tokens, and returns the best candidate if it clears a
 * confidence threshold.
 */
object ElementFinder {

    private const val TAG = "Waylo"

    /** Minimum score required for a match to be considered reliable. */
    private const val MIN_SCORE = 30

    /**
     * Filler words that pollute scoring when the backend sends rich, sentence
     * style descriptions. These are removed before tokenising.
     */
    private val STOP_WORDS = setOf(
        "the", "a", "an", "which", "is", "are", "in", "on", "at",
        "to", "of", "with", "and", "or", "that", "this", "it", "its",
        "there", "their", "has", "have", "be", "been", "being",
        "middle", "bottom", "top", "left", "right", "corner", "button",
        "icon", "screen", "page", "app"
    )

    /** Known launcher packages where home-screen app icons live. */
    private val LAUNCHER_PACKAGES = setOf(
        "com.google.android.apps.nexuslauncher",
        "com.sec.android.app.launcher",
        "com.miui.home",
        "com.android.launcher",
        "com.android.launcher3",
        "com.oneplus.launcher"
    )

    data class MatchResult(
        val node: AccessibilityNodeInfo,
        val score: Int,
        val matchReason: String
    )

    /** Per-field score breakdown, used for verbose logging. */
    private data class ScoreBreakdown(
        val total: Int,
        val parts: List<String>
    )

    /**
     * Find the best on-screen element matching [rawDescription].
     *
     * The raw description (often a full sentence from the backend) is cleaned by
     * stripping punctuation and stop words, leaving only meaningful tokens to
     * score against. Returns null if no node clears [MIN_SCORE] or the service
     * is not connected.
     */
    fun findElement(
        rawDescription: String,
        targetPackage: String? = null,
        alternateLabels: List<String> = emptyList()
    ): MatchResult? {
        // Strip filler words, keep only meaningful tokens.
        val tokens = rawDescription.lowercase()
            .replace(Regex("[^a-z0-9 ]"), " ")
            .split(" ")
            .filter { it.length > 2 && it !in STOP_WORDS }
        val cleanedDescription = tokens.joinToString(" ")
        Log.e("WAYLO_DOT", "findElement: raw='$rawDescription' → cleaned='$cleanedDescription' targetPkg=$targetPackage")

        val service = WayloAccessibilityService.instance ?: run {
            Log.e("WAYLO_DOT", "findElement: accessibility service not connected!")
            return null
        }

        val allNodes = service.getAllNodes()
        Log.e("WAYLO_DOT", "findElement: scanning ${allNodes.size} nodes for '$cleanedDescription'")

        val scored = allNodes
            .map { node -> Pair(node, scoreNodeWithBreakdown(node, cleanedDescription, tokens, targetPackage, alternateLabels)) }
            .filter { it.second.total > 0 }
            .sortedByDescending { it.second.total }

        val top3 = scored.take(3)
        top3.forEach { (node, breakdown) ->
            Log.e(
                "WAYLO_DOT",
                "  Candidate: score=${breakdown.total} desc='${node.contentDescription}' " +
                    "text='${node.text}' viewId='${node.viewIdResourceName}' pkg='${node.packageName}' " +
                    "[${breakdown.parts.joinToString(", ")}]"
            )
        }

        val best = scored.firstOrNull()
        return if (best != null && best.second.total > MIN_SCORE) {
            Log.e("WAYLO_DOT", "findElement: FOUND '${best.first.contentDescription}' score=${best.second.total}")
            MatchResult(best.first, best.second.total, cleanedDescription)
        } else {
            Log.e("WAYLO_DOT", "findElement: NOT FOUND (best score=${best?.second?.total ?: 0}, threshold=$MIN_SCORE)")
            null
        }
    }

    /**
     * Like [findElement] but only considers nodes that belong to a known
     * launcher package. Used for Step 1 of a task ("find the app icon").
     */
    fun findOnHomeScreen(
        rawDescription: String,
        targetPackage: String? = null,
        alternateLabels: List<String> = emptyList()
    ): MatchResult? {
        val tokens = rawDescription.lowercase()
            .replace(Regex("[^a-z0-9 ]"), " ")
            .split(" ")
            .filter { it.length > 2 && it !in STOP_WORDS }
        val cleanedDescription = tokens.joinToString(" ")

        val service = WayloAccessibilityService.instance
        if (service == null) {
            Log.d(TAG, "findOnHomeScreen: accessibility service not connected.")
            return null
        }

        val launcherNodes = service.getAllNodes().filter { node ->
            val pkg = node.packageName?.toString()
            pkg != null && LAUNCHER_PACKAGES.contains(pkg)
        }
        Log.d(TAG, "findOnHomeScreen: '$cleanedDescription' across ${launcherNodes.size} launcher nodes.")
        if (launcherNodes.isEmpty()) {
            Log.d(TAG, "findOnHomeScreen: no launcher nodes (is the home screen visible?).")
            return null
        }

        val scored = launcherNodes
            .map { node -> Pair(node, scoreNodeWithBreakdown(node, cleanedDescription, tokens, targetPackage, alternateLabels)) }
            .sortedByDescending { it.second.total }

        scored.take(3).forEachIndexed { i, (node, breakdown) ->
            Log.e(
                "WAYLO_DOT",
                "  home #${i + 1} score=${breakdown.total} text='${node.text}' " +
                    "desc='${node.contentDescription}' viewId='${node.viewIdResourceName}' " +
                    "pkg='${node.packageName}' [${breakdown.parts.joinToString(", ")}]"
            )
        }

        val best = scored.firstOrNull()
        return if (best != null && best.second.total > MIN_SCORE) {
            Log.e("WAYLO_DOT", "findOnHomeScreen: FOUND (score ${best.second.total}).")
            MatchResult(best.first, best.second.total, "homeScreen")
        } else {
            Log.e("WAYLO_DOT", "findOnHomeScreen: NOT FOUND (best ${best?.second?.total ?: 0}).")
            null
        }
    }

    /**
     * Score a single node against [description]. Public entry point that
     * tokenises the description itself (used by tests and ad-hoc callers).
     */
    fun scoreNode(node: AccessibilityNodeInfo, description: String): Int {
        val tokens = description.lowercase().trim()
            .split(Regex("\\s+"))
            .filter { it.isNotBlank() }
        return scoreNodeWithBreakdown(node, description.lowercase().trim(), tokens).total
    }

    /**
     * Score a node and capture which fields contributed what, for verbose
     * logging. Uses the supplied [tokens] for word-level matching.
     */
    private fun scoreNodeWithBreakdown(
        node: AccessibilityNodeInfo,
        description: String,
        tokens: List<String>,
        targetPackage: String? = null,
        alternateLabels: List<String> = emptyList()
    ): ScoreBreakdown {
        var score = 0
        val parts = mutableListOf<String>()
        val desc = description.lowercase().trim()

        val contentDesc = node.contentDescription?.toString()?.lowercase()?.trim()
        val text = node.text?.toString()?.lowercase()?.trim()
        val viewId = node.viewIdResourceName?.substringAfterLast('/')?.lowercase()?.trim()

        // Strong preference for the target app's package (e.g. the real
        // com.google.android.youtube icon over the Play Store listing).
        // Callers MUST only pass targetPackage for a search that spans
        // multiple packages (the home screen) — once already inside the
        // target app, every visible node shares this package, so the bonus
        // adds no discriminating signal and can let an unrelated but
        // clickable+visible icon (+15+10) clear the confidence floor on this
        // +50 alone. See GuidanceEngine.locateOnDevice()/checkTapInAppEvidence().
        if (targetPackage != null && node.packageName?.toString() == targetPackage) {
            score += 50; parts.add("targetPackage($targetPackage) +50")
        }

        // contentDescription matching
        if (!contentDesc.isNullOrBlank() && desc.isNotBlank()) {
            if (contentDesc == desc) {
                score += 60; parts.add("contentDesc exact +60")
            } else if (contentDesc.contains(desc) || desc.contains(contentDesc)) {
                score += 40; parts.add("contentDesc partial +40")
            }
        }

        // text matching
        if (!text.isNullOrBlank() && desc.isNotBlank()) {
            if (text == desc) {
                score += 50; parts.add("text exact +50")
            } else if (text.contains(desc) || desc.contains(text)) {
                score += 30; parts.add("text partial +30")
            }
        }

        // Backend-supplied alternate labels for this element (small additive
        // bonus only — the primary contentDesc/text matching above still does
        // the heavy lifting).
        if (alternateLabels.isNotEmpty()) {
            var altHits = 0
            for (rawLabel in alternateLabels) {
                val label = rawLabel.lowercase().trim()
                if (label.isBlank()) continue
                val matches = (!contentDesc.isNullOrBlank() && (contentDesc == label || contentDesc.contains(label))) ||
                    (!text.isNullOrBlank() && (text == label || text.contains(label)))
                if (matches) altHits++
            }
            if (altHits > 0) {
                score += altHits * 15
                parts.add("alternateLabels x$altHits +${altHits * 15}")
            }
        }

        // viewId (last segment) matching
        if (!viewId.isNullOrBlank()) {
            if (tokens.any { viewId.contains(it) } || (desc.isNotBlank() && desc.contains(viewId))) {
                score += 35; parts.add("viewId '$viewId' +35")
            }
        }

        // affordance bonuses
        if (node.isClickable) {
            score += 15; parts.add("clickable +15")
        }
        if (node.isVisibleToUser) {
            score += 10; parts.add("visible +10")
        }

        // Launcher icon class hints (Launcher3 / common launchers).
        val className = node.className?.toString() ?: ""
        if (className.contains("IconView") || className.contains("BubbleTextView")) {
            score += 20; parts.add("launcherIconClass +20")
        }

        // Home-screen package bonus: a matching node living in a known launcher
        // is very likely the app icon we want.
        val pkg = node.packageName?.toString()
        val isLauncher = pkg != null && LAUNCHER_PACKAGES.contains(pkg)
        val anyFieldMatches =
            (desc.isNotBlank() && contentDesc?.contains(desc) == true) ||
                (desc.isNotBlank() && text?.contains(desc) == true) ||
                (desc.isNotBlank() && viewId?.contains(desc) == true) ||
                tokens.any { t ->
                    contentDesc?.contains(t) == true ||
                        text?.contains(t) == true ||
                        viewId?.contains(t) == true
                }
        if (isLauncher && anyFieldMatches) {
            score += 25; parts.add("homeScreenNode($pkg) +25")
        }

        // per-word presence across any field (cumulative)
        var wordHits = 0
        for (token in tokens) {
            val inDesc = contentDesc?.contains(token) == true
            val inText = text?.contains(token) == true
            val inId = viewId?.contains(token) == true
            if (inDesc || inText || inId) {
                score += 10
                wordHits++
            }
        }
        if (wordHits > 0) parts.add("wordMatches x$wordHits +${wordHits * 10}")

        return ScoreBreakdown(score, parts)
    }

    /**
     * Bounds of a node in absolute screen coordinates.
     */
    fun getBoundsOnScreen(node: AccessibilityNodeInfo): Rect {
        val rect = Rect()
        node.getBoundsInScreen(rect)
        return rect
    }

    /** True if [pkg] is a known home-screen launcher package. */
    fun isLauncherPackage(pkg: String): Boolean = LAUNCHER_PACKAGES.contains(pkg)
}
