// TODO: Day 9 — implement parsing of the backend's JSON plan into Step objects.
package com.waylo.ai

/**
 * Core data model shared across guidance. A single instruction in a plan.
 *
 * @param index            1-based position in the plan.
 * @param instruction      Simple instruction shown/spoken to the user.
 * @param findDescription  English description of the UI element to locate.
 */
data class Step(
    val index: Int,
    val instruction: String,
    val findDescription: String
)

/**
 * Parses the JSON plan returned by the backend into a list of [Step].
 */
object PlanParser {

    /** TODO: Day 9 — parse the plan JSON string into List<Step>. */
    fun parse(json: String): List<Step> {
        // TODO
        return emptyList()
    }
}
