package com.waylo.data

import android.content.Context
import android.util.Log
import com.waylo.ai.PlanParser
import org.json.JSONObject

/**
 * Loads pre-built step guides bundled in the APK (assets/guides.json) and
 * matches a user task against them. A hit means zero network/API cost for the
 * most common tasks on the most common apps.
 *
 * Matching is keyword-based and deliberately lenient — elderly users phrase the
 * same task many ways ("send whatsapp message", "message on whatsapp", etc.).
 */
object PrebuiltGuides {

    private const val TAG = "WAYLO_DOT"

    private data class Guide(
        val task: String,
        val keywords: List<String>,
        val planJson: String
    )

    @Volatile
    private var guides: List<Guide>? = null

    /** Parse assets/guides.json once and keep it in memory. */
    private fun load(context: Context): List<Guide> {
        guides?.let { return it }
        synchronized(this) {
            guides?.let { return it }
            val parsed = try {
                val raw = context.applicationContext.assets.open("guides.json")
                    .bufferedReader().use { it.readText() }
                val root = JSONObject(raw)
                val arr = root.optJSONArray("guides")
                val out = mutableListOf<Guide>()
                if (arr != null) {
                    for (i in 0 until arr.length()) {
                        val g = arr.getJSONObject(i)
                        val task = g.optString("task", "")
                        val kw = mutableListOf<String>()
                        g.optJSONArray("matchKeywords")?.let { ks ->
                            for (j in 0 until ks.length()) {
                                ks.optString(j)?.takeIf { it.isNotBlank() }?.let { kw.add(it.lowercase()) }
                            }
                        }
                        if (task.isNotBlank()) kw.add(task.lowercase())
                        // The guide object itself is already in the plan JSON shape
                        // (appPackage, appName, steps), so PlanParser.parse can read it.
                        out.add(Guide(task, kw, g.toString()))
                    }
                }
                Log.e(TAG, "PrebuiltGuides: loaded ${out.size} bundled guides")
                out
            } catch (e: Exception) {
                Log.w(TAG, "PrebuiltGuides: no bundled guides (${e.message})")
                emptyList()
            }
            guides = parsed
            return parsed
        }
    }

    /**
     * Return a bundled plan matching [task], or null. A guide matches when any
     * of its keywords is contained in the task, or the task is contained in a
     * keyword (handles both "send whatsapp" and "send a message on whatsapp").
     */
    fun find(context: Context, task: String): PlanParser.Plan? {
        val t = task.lowercase().trim()
        if (t.isEmpty()) return null
        val match = load(context).firstOrNull { g ->
            g.keywords.any { kw -> t.contains(kw) || kw.contains(t) }
        } ?: return null
        Log.e(TAG, "PrebuiltGuides: HIT for '$task' -> '${match.task}'")
        val plan = PlanParser.parse(match.planJson)
        return if (plan.steps.isNotEmpty()) plan else null
    }
}
