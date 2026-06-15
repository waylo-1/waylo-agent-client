package com.waylo.ai

import android.util.Log
import com.waylo.guidance.ElementType
import com.waylo.guidance.ScreenRegion
import com.waylo.guidance.StepMetadata
import org.json.JSONObject

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
 * Parses the JSON plan returned by the backend into rich [StepMetadata]
 * objects (the enriched 8-field format) and, for backward compatibility, into
 * the thin [Step] model used by the existing guidance flow.
 */
object PlanParser {

    private const val TAG = "WAYLO_DOT"

    /**
     * Parse the full `/plan` response body. Returns the parsed app package plus
     * the enriched step metadata. Missing fields fall back to safe defaults so a
     * partial backend response never crashes guidance.
     */
    data class Plan(
        val appPackage: String,
        val appName: String,
        val steps: List<StepMetadata>
    )

    fun parse(json: String): Plan {
        return try {
            val obj = JSONObject(json)
            val appPackage = obj.optString("appPackage", "")
            val appName = obj.optString("appName", "")
            val stepsArray = obj.optJSONArray("steps")
            val steps = mutableListOf<StepMetadata>()
            if (stepsArray != null) {
                for (i in 0 until stepsArray.length()) {
                    steps.add(parseStep(stepsArray.getJSONObject(i), i + 1))
                }
            }
            Log.e(TAG, "PlanParser: appPackage=$appPackage appName=$appName steps=${steps.size}")
            Plan(appPackage, appName, steps)
        } catch (e: Exception) {
            Log.e(TAG, "PlanParser.parse FAILED: ${e.message} | json: $json", e)
            Plan("", "", emptyList())
        }
    }

    /** Map a single JSON step object into [StepMetadata] with safe defaults. */
    fun parseStep(s: JSONObject, fallbackNumber: Int): StepMetadata {
        val alternateLabels = mutableListOf<String>()
        s.optJSONArray("alternateLabels")?.let { arr ->
            for (i in 0 until arr.length()) {
                arr.optString(i)?.takeIf { it.isNotBlank() }?.let { alternateLabels.add(it) }
            }
        }

        return StepMetadata(
            stepNumber = s.optInt("stepNumber", fallbackNumber),
            instruction = s.optString("instruction", "Follow the dot"),
            findDescription = s.optString("findDescription", ""),
            elementType = ElementType.from(s.optString("elementType", "OTHER")),
            screenRegion = ScreenRegion.from(s.optString("screenRegion", "CENTER")),
            visualDescription = s.optString("visualDescription", ""),
            alternateLabels = alternateLabels,
            fallbackHint = s.optString("fallbackHint", "scroll down to find the element"),
            parentContainer = s.optString("parentContainer", "")
        )
    }

    /** Backward-compatible thin view of a step. */
    fun toStep(meta: StepMetadata): Step =
        Step(meta.stepNumber, meta.instruction, meta.findDescription)

    /**
     * Promote a thin [Step] (demo tasks, legacy callers, vision recovery steps)
     * into [StepMetadata] with safe enum defaults. The richer detection signal
     * simply isn't present for these, so layers fall back to text matching.
     */
    fun toMetadata(step: Step): StepMetadata =
        StepMetadata(
            stepNumber = step.index,
            instruction = step.instruction,
            findDescription = step.findDescription,
            elementType = ElementType.OTHER,
            screenRegion = ScreenRegion.CENTER,
            visualDescription = "",
            alternateLabels = emptyList(),
            fallbackHint = "scroll down to find the element",
            parentContainer = ""
        )
}
