package com.waylo.guidance

/**
 * Rich, enriched description of a single step's target element.
 *
 * Produced by the backend's enriched step planner and parsed on-device by
 * [com.waylo.ai.PlanParser]. Every detection layer (L0 accessibility tree,
 * L1 ML Kit OCR, L2 icon/colour matching, L3 vision) scores candidates against
 * this metadata via [SemanticMatcher]. More signal here means fewer expensive
 * vision fallbacks.
 */
data class StepMetadata(
    val stepNumber: Int,
    val instruction: String,
    val findDescription: String,
    val elementType: ElementType,
    val screenRegion: ScreenRegion,
    val visualDescription: String,
    val alternateLabels: List<String>,
    val fallbackHint: String,
    val parentContainer: String
)

/** The kind of UI control a step targets. Mirrors the backend enum. */
enum class ElementType {
    BUTTON, ICON_BUTTON, FAB, TEXT_INPUT, NAV_ITEM, TOGGLE,
    APP_ICON, LIST_ITEM, IMAGE, TAB, OVERFLOW_MENU, BACK_BUTTON, OTHER;

    companion object {
        /** Safe parse: unknown strings fall back to [OTHER]. */
        fun from(value: String): ElementType =
            values().firstOrNull { it.name == value.uppercase() } ?: OTHER
    }
}

/** Where on the physical screen a step's target element lives. */
enum class ScreenRegion {
    TOP, TOP_CENTER, BOTTOM, BOTTOM_RIGHT, CENTER, LEFT, RIGHT, FULL;

    companion object {
        /** Safe parse: unknown strings fall back to [CENTER]. */
        fun from(value: String): ScreenRegion =
            values().firstOrNull { it.name == value.uppercase() } ?: CENTER
    }
}
