package com.waylo.ai

import android.util.Log
import org.json.JSONObject

/**
 * Core data model shared across guidance. A single instruction in a plan.
 *
 * @param index              1-based position in the plan.
 * @param instruction        Simple instruction shown/spoken to the user.
 * @param findDescription    English description of the UI element to locate.
 * @param elementType        Backend hint for the kind of control (e.g. "APP_ICON"). Absent on older/cached plans.
 * @param screenRegion       Backend hint for where on screen the element lives (e.g. "center"). Absent on older/cached plans.
 * @param visualDescription  Free-text visual description, used to widen OCR matching.
 * @param alternateLabels    Extra labels ElementFinder should also match against.
 * @param fallbackHint       Backend's suggestion for what to do if the element isn't found.
 * @param parentContainer    Backend hint for the containing UI region/component.
 */
data class Step(
    val index: Int,
    val instruction: String,
    val findDescription: String,
    val elementType: String? = null,
    val screenRegion: String? = null,
    val visualDescription: String? = null,
    val alternateLabels: List<String> = emptyList(),
    val fallbackHint: String? = null,
    val parentContainer: String? = null
)

/**
 * A parsed backend plan: which app it targets, plus the ordered steps.
 */
data class Plan(
    val appPackage: String?,
    val appName: String?,
    val steps: List<Step>
)

/**
 * Parses the JSON plan returned by the backend's `/plan` endpoint into a [Plan].
 */
object PlanParser {

    private const val TAG = "WAYLO_DOT"

    /**
     * Parse the full `/plan` response body. Returns null if the backend
     * reported failure (`success: false`) or the JSON couldn't be parsed.
     * Enriched per-step fields are optional so an older/cached response
     * without them still parses instead of crashing.
     */
    fun parse(json: String): Plan? {
        return try {
            val obj = JSONObject(json)
            if (!obj.optBoolean("success", false)) {
                Log.e(TAG, "PlanParser: backend returned success=false: $json")
                return null
            }
            val stepsArray = obj.optJSONArray("steps") ?: return null
            val steps = mutableListOf<Step>()
            for (i in 0 until stepsArray.length()) {
                val s = stepsArray.getJSONObject(i)
                val alternateLabels = s.optJSONArray("alternateLabels")?.let { arr ->
                    (0 until arr.length()).map { arr.optString(it) }.filter { it.isNotBlank() }
                } ?: emptyList()
                steps.add(
                    Step(
                        index = s.optInt("stepNumber", i + 1),
                        instruction = s.optString("instruction", "Follow the dot"),
                        findDescription = s.optString("findDescription", ""),
                        elementType = s.optString("elementType").takeIf { it.isNotBlank() },
                        screenRegion = s.optString("screenRegion").takeIf { it.isNotBlank() },
                        visualDescription = s.optString("visualDescription").takeIf { it.isNotBlank() },
                        alternateLabels = alternateLabels,
                        fallbackHint = s.optString("fallbackHint").takeIf { it.isNotBlank() },
                        parentContainer = s.optString("parentContainer").takeIf { it.isNotBlank() }
                    )
                )
            }
            val plan = Plan(
                appPackage = obj.optString("appPackage").takeIf { it.isNotBlank() },
                appName = obj.optString("appName").takeIf { it.isNotBlank() },
                steps = steps
            )
            Log.e(TAG, "PlanParser: parsed ${steps.size} steps, appPackage=${plan.appPackage}")
            plan
        } catch (e: Exception) {
            Log.e(TAG, "PlanParser: parse FAILED: ${e.message} | json: $json", e)
            null
        }
    }
}
