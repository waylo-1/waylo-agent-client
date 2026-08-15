package com.waylo.accessibility

import com.waylo.diagnostics.WayloVerify

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
     * Waylo's own package. Never a legitimate guidance target — excluded from
     * [findElement]'s general scan so the dot can never be placed on Waylo's
     * own UI (e.g. its own recent-task list happening to contain the target
     * app's name as text). [findOnHomeScreen] doesn't need this: it's already
     * restricted to [LAUNCHER_PACKAGES], which never includes this one.
     */
    private const val OWN_PACKAGE = "com.waylo"

    /**
     * Confidence floor for [MatchResult.isConfident]. Calibrated from observed
     * score distributions: a candidate with zero real signal (no text/desc/
     * viewId/label match — just clickable+visible affordance) caps at exactly
     * 25 everywhere we've measured it. Any genuine match component adds at
     * least +10, so 35 cleanly separates "some real signal" from "pure noise"
     * without the old flat 50 rejecting weak-but-real matches (e.g. a single
     * alternate-label hit scoring 40).
     */
    private const val MIN_CONFIDENT_SCORE = 35

    /**
     * A confident top candidate must also clearly beat the runner-up by this
     * margin, so a screen full of near-tied noise (or near-tied real
     * candidates) doesn't get an arbitrary winner picked just because it
     * crossed [MIN_CONFIDENT_SCORE].
     */
    private const val MIN_CONFIDENCE_GAP = 10

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
        val matchReason: String,
        /** The second-highest score among candidates, or 0 if this was the only one. */
        val runnerUpScore: Int = 0
    ) {
        /**
         * Stricter than the raw [MIN_SCORE] gate `findElement`/`findOnHomeScreen`
         * already apply — this is the bar for trusting a match enough to place
         * (or move) the dot on it. See [MIN_CONFIDENT_SCORE]/[MIN_CONFIDENCE_GAP].
         */
        fun isConfident(): Boolean = score >= MIN_CONFIDENT_SCORE && (score - runnerUpScore) >= MIN_CONFIDENCE_GAP
    }

    /** Per-field score breakdown, used for verbose logging. */
    private data class ScoreBreakdown(
        val total: Int,
        val parts: List<String>
    )

    /**
     * WAYLO_VERIFY diagnostic log for a single tree-scan attempt (findElement/
     * findOnHomeScreen/scorePartialMatch). Reports confidence against the SAME
     * gate as [MatchResult.isConfident] (MIN_CONFIDENT_SCORE/MIN_CONFIDENCE_GAP)
     * regardless of which looser threshold the calling function itself uses
     * for its own null-return decision, so this always reflects why the dot
     * would or wouldn't actually be placed. Logging only — does not read or
     * affect any return value. [stepIndex] is -1 when the caller has no step
     * context (e.g. an ad-hoc/test caller).
     */
    private fun logTreeScan(stepIndex: Int, scored: List<Pair<AccessibilityNodeInfo, ScoreBreakdown>>) {
        val top = scored.getOrNull(0)
        val runnerUp = scored.getOrNull(1)
        val topScore = top?.second?.total ?: 0
        val runnerUpScore = runnerUp?.second?.total ?: 0
        val gap = topScore - runnerUpScore
        val confident = top != null && topScore >= MIN_CONFIDENT_SCORE && gap >= MIN_CONFIDENCE_GAP
        val failReason = when {
            top == null -> "no_candidates"
            topScore < MIN_CONFIDENT_SCORE -> "below_floor"
            gap < MIN_CONFIDENCE_GAP -> "gap_too_small"
            else -> "passed"
        }
        val top3 = scored.take(3).joinToString(" ") { (node, breakdown) ->
            "(score=${breakdown.total},text=${node.text?.toString()?.take(40) ?: ""},desc=${node.contentDescription?.toString()?.take(40) ?: ""})"
        }
        WayloVerify.d("TREE_SCAN | stepIndex=$stepIndex | candidateCount=${scored.size} | topScore=$topScore | " +
                "topText=${top?.first?.text?.toString()?.take(80) ?: ""} | topContentDesc=${top?.first?.contentDescription?.toString()?.take(80) ?: ""} | " +
                "topViewId=${top?.first?.viewIdResourceName ?: ""} | runnerUpScore=$runnerUpScore | " +
                "runnerUpText=${runnerUp?.first?.text?.toString()?.take(80) ?: ""} | gap=$gap | confident=$confident | " +
                "failReason=$failReason | top3=$top3"
        )
    }

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
        alternateLabels: List<String> = emptyList(),
        stepIndex: Int = -1
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

        // Never consider our own UI a guidance target (see OWN_PACKAGE).
        val allNodes = service.getAllNodes().filter { it.packageName?.toString() != OWN_PACKAGE }
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

        logTreeScan(stepIndex, scored)

        val best = scored.firstOrNull()
        val runnerUp = scored.getOrNull(1)?.second?.total ?: 0
        return if (best != null && best.second.total > MIN_SCORE) {
            Log.e("WAYLO_DOT", "findElement: FOUND '${best.first.contentDescription}' score=${best.second.total} runnerUp=$runnerUp")
            MatchResult(best.first, best.second.total, cleanedDescription, runnerUp)
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
        alternateLabels: List<String> = emptyList(),
        stepIndex: Int = -1
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

        logTreeScan(stepIndex, scored)

        val best = scored.firstOrNull()
        val runnerUp = scored.getOrNull(1)?.second?.total ?: 0
        return if (best != null && best.second.total > MIN_SCORE) {
            Log.e("WAYLO_DOT", "findOnHomeScreen: FOUND (score ${best.second.total}, runnerUp=$runnerUp).")
            MatchResult(best.first, best.second.total, "homeScreen", runnerUp)
        } else {
            Log.e("WAYLO_DOT", "findOnHomeScreen: NOT FOUND (best ${best?.second?.total ?: 0}).")
            null
        }
    }

    /** A single element to search for — see [scanMultiple]. */
    data class ElementQuery(val findDescription: String, val alternateLabels: List<String> = emptyList())

    /**
     * Score each of [queries] against the SAME node-tree snapshot in one pass.
     * Used by GuidanceEngine's screen-aware step-skip lookahead: checking a
     * step's target plus several steps ahead this way costs one extra tree
     * walk total (this function's own [WayloAccessibilityService.getAllNodes]
     * call), not one per step. Returns a result per query, in the same order;
     * `null` where nothing cleared [MIN_SCORE].
     */
    fun scanMultiple(queries: List<ElementQuery>, targetPackage: String? = null): List<MatchResult?> {
        if (queries.isEmpty()) return emptyList()
        val service = WayloAccessibilityService.instance ?: return queries.map { null }
        val allNodes = service.getAllNodes().filter { it.packageName?.toString() != OWN_PACKAGE }
        return scoreMultiple(allNodes, queries, targetPackage)
    }

    /**
     * Pure scoring core for [scanMultiple] — takes the node snapshot directly
     * so it's testable without a live [WayloAccessibilityService].
     */
    fun scoreMultiple(
        allNodes: List<AccessibilityNodeInfo>,
        queries: List<ElementQuery>,
        targetPackage: String? = null
    ): List<MatchResult?> = queries.map { query ->
        val tokens = query.findDescription.lowercase()
            .replace(Regex("[^a-z0-9 ]"), " ")
            .split(" ")
            .filter { it.length > 2 && it !in STOP_WORDS }
        val cleaned = tokens.joinToString(" ")
        val scored = allNodes
            .map { node -> Pair(node, scoreNodeWithBreakdown(node, cleaned, tokens, targetPackage, query.alternateLabels)) }
            .filter { it.second.total > 0 }
            .sortedByDescending { it.second.total }
        val best = scored.firstOrNull()
        val runnerUp = scored.getOrNull(1)?.second?.total ?: 0
        if (best != null && best.second.total > MIN_SCORE) {
            MatchResult(best.first, best.second.total, cleaned, runnerUp)
        } else null
    }

    /**
     * Last-resort search used only after the primary findDescription search
     * has failed for a step's *entire* patient window. Scores directly
     * against the step's semantic-goal hints — [alternateLabels] (via the
     * existing altHits bonus) and the individual words of [visualDescription]
     * (via the existing desc/wordHits bonuses) — rather than the
     * findDescription that just failed.
     *
     * Despite the name, this is NOT a lowered-confidence path: it still
     * requires the full [MatchResult.isConfident] gate (score floor AND
     * runner-up gap). The dot must never be placed below that bar — see
     * GuidanceEngine's confidence-floor policy. Returns null if there's
     * nothing to search with (no alternateLabels AND no visualDescription
     * words) or nothing clears [MatchResult.isConfident].
     */
    fun findPartialMatch(
        alternateLabels: List<String>,
        visualDescription: String?,
        targetPackage: String? = null,
        stepIndex: Int = -1
    ): MatchResult? {
        val service = WayloAccessibilityService.instance ?: return null
        val allNodes = service.getAllNodes().filter { it.packageName?.toString() != OWN_PACKAGE }
        return scorePartialMatch(allNodes, alternateLabels, visualDescription, targetPackage, stepIndex)
    }

    /**
     * Pure scoring core for [findPartialMatch] — takes the node snapshot
     * directly so it's testable without a live [WayloAccessibilityService].
     */
    fun scorePartialMatch(
        allNodes: List<AccessibilityNodeInfo>,
        alternateLabels: List<String>,
        visualDescription: String?,
        targetPackage: String? = null,
        stepIndex: Int = -1
    ): MatchResult? {
        val visualTokens = visualDescription.orEmpty().lowercase()
            .replace(Regex("[^a-z0-9 ]"), " ")
            .split(" ")
            .filter { it.length > 2 && it !in STOP_WORDS }
        if (alternateLabels.isEmpty() && visualTokens.isEmpty()) return null

        val cleanedVisual = visualTokens.joinToString(" ")
        val scored = allNodes
            .map { node -> Pair(node, scoreNodeWithBreakdown(node, cleanedVisual, visualTokens, targetPackage, alternateLabels)) }
            .filter { it.second.total > 0 }
            .sortedByDescending { it.second.total }
        logTreeScan(stepIndex, scored)
        val best = scored.firstOrNull() ?: return null
        val runnerUp = scored.getOrNull(1)?.second?.total ?: 0
        val result = MatchResult(best.first, best.second.total, cleanedVisual.ifBlank { alternateLabels.joinToString(" ") }, runnerUp)
        return if (result.isConfident()) result else null
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
