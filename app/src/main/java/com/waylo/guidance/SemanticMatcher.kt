package com.waylo.guidance

import android.graphics.Rect
import android.view.accessibility.AccessibilityNodeInfo

/**
 * Scores a detection candidate (an accessibility node or an OCR text block)
 * against a [StepMetadata]. Shared by L0 ([com.waylo.accessibility.ElementFinder]),
 * L1 ([com.waylo.ocr.OcrAnalyzer]) and, eventually, L2 (icon/YOLO matching).
 *
 * All scores are normalised to 0..100.
 */
object SemanticMatcher {

    /**
     * Score an [AccessibilityNodeInfo] against [step]. Returns 0..100.
     * Acceptance threshold (in ElementFinder) is 70.
     */
    fun scoreNode(
        node: AccessibilityNodeInfo,
        step: StepMetadata,
        screenWidth: Int,
        screenHeight: Int
    ): Int {
        var score = 0

        // --- Text matching (0-40 points) ---
        val nodeText = listOfNotNull(
            node.text?.toString(),
            node.contentDescription?.toString(),
            node.viewIdResourceName?.substringAfterLast("/")
        ).joinToString(" ").lowercase()

        val primaryTokens = step.findDescription.lowercase().split(" ").filter { it.length > 2 }
        val allLabels = (step.alternateLabels + step.findDescription).map { it.lowercase() }

        // Exact label match
        if (allLabels.any { label -> label.isNotBlank() && nodeText.contains(label) }) score += 30
        // Token overlap
        val matchedTokens = primaryTokens.count { token -> nodeText.contains(token) }
        score += (matchedTokens.toFloat() / primaryTokens.size.coerceAtLeast(1) * 10).toInt()

        // --- Element type matching (0-30 points) ---
        score += scoreElementType(node, step.elementType)

        // --- Screen region matching (0-20 points) ---
        val nodeBounds = Rect()
        node.getBoundsInScreen(nodeBounds)
        if (isInRegion(nodeBounds, step.screenRegion, screenWidth, screenHeight)) score += 20

        // --- Parent container matching (0-10 points) ---
        if (step.parentContainer.isNotBlank()) {
            val parentText = node.parent?.contentDescription?.toString()?.lowercase() ?: ""
            val parentId = node.parent?.viewIdResourceName?.lowercase() ?: ""
            val containerKeywords = step.parentContainer.lowercase().split(" ")
            if (containerKeywords.any { kw -> kw.isNotBlank() && (parentText.contains(kw) || parentId.contains(kw)) }) {
                score += 10
            }
        }

        return score.coerceIn(0, 100)
    }

    /**
     * Score a text string (from OCR) against [step]. Returns 0..100.
     * Used by the L1 OCR layer; threshold there is 60 (OCR is less precise).
     */
    fun scoreText(
        ocrText: String,
        step: StepMetadata,
        boundingBox: Rect,
        screenWidth: Int,
        screenHeight: Int
    ): Int {
        var score = 0
        val text = ocrText.lowercase()
        val allLabels = (step.alternateLabels + step.findDescription).map { it.lowercase() }

        if (allLabels.any { it.isNotBlank() && text.contains(it) }) {
            score += 50
        } else {
            val tokens = step.findDescription.lowercase().split(" ").filter { it.length > 2 }
            val matched = tokens.count { text.contains(it) }
            score += (matched.toFloat() / tokens.size.coerceAtLeast(1) * 30).toInt()
        }

        if (isInRegion(boundingBox, step.screenRegion, screenWidth, screenHeight)) score += 30
        if (step.elementType == ElementType.BUTTON || step.elementType == ElementType.NAV_ITEM) score += 20

        return score.coerceIn(0, 100)
    }

    private fun scoreElementType(node: AccessibilityNodeInfo, expected: ElementType): Int {
        val className = node.className?.toString() ?: ""
        return when (expected) {
            ElementType.BUTTON ->
                if (node.isClickable && (className.contains("Button") || className.contains("TextView"))) 30 else 0
            ElementType.ICON_BUTTON ->
                if (node.isClickable && className.contains("ImageView")) 30 else 0
            ElementType.FAB ->
                if (node.isClickable && className.contains("FloatingAction")) 30 else 10
            ElementType.TEXT_INPUT ->
                if (className.contains("EditText") || className.contains("SearchView")) 30 else 0
            ElementType.NAV_ITEM ->
                if (node.isClickable && (className.contains("BottomNav") ||
                        node.parent?.className?.toString()?.contains("BottomNav") == true)) 30 else 5
            ElementType.TOGGLE ->
                if (className.contains("Switch") || className.contains("CheckBox")) 30 else 0
            ElementType.APP_ICON ->
                if (node.isClickable && className.contains("ImageView")) 20 else 5
            ElementType.LIST_ITEM ->
                if (node.isClickable && className.contains("RecyclerView").not()) 20 else 10
            ElementType.OVERFLOW_MENU ->
                if (node.contentDescription?.toString()?.lowercase()?.contains("more") == true) 30 else 0
            ElementType.BACK_BUTTON ->
                if (node.contentDescription?.toString()?.lowercase()?.contains("back") == true ||
                    node.contentDescription?.toString()?.lowercase()?.contains("navigate up") == true) 30 else 0
            else -> if (node.isClickable) 10 else 0
        }
    }

    /** True if [bounds]' centre lies within [region] of a [screenW] x [screenH] screen. */
    fun isInRegion(bounds: Rect, region: ScreenRegion, screenW: Int, screenH: Int): Boolean {
        if (screenW <= 0 || screenH <= 0) return true
        val cx = bounds.centerX().toFloat() / screenW
        val cy = bounds.centerY().toFloat() / screenH
        return when (region) {
            ScreenRegion.TOP -> cy < 0.25f
            ScreenRegion.TOP_CENTER -> cy < 0.25f && cx in 0.25f..0.75f
            ScreenRegion.BOTTOM -> cy > 0.75f
            ScreenRegion.BOTTOM_RIGHT -> cy > 0.75f && cx > 0.6f
            ScreenRegion.CENTER -> cy in 0.2f..0.8f
            ScreenRegion.LEFT -> cx < 0.25f
            ScreenRegion.RIGHT -> cx > 0.75f
            ScreenRegion.FULL -> true
        }
    }
}
