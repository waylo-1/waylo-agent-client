package com.waylo.data

import android.content.Context
import org.json.JSONArray

/**
 * Persists the user's most recent tasks (typed, spoken, or tapped from a
 * quick-task card) so they can be re-run with one tap from the home screen.
 * Backed by SharedPreferences — a single JSON array, most-recent-first,
 * capped at [MAX_RECENTS] and de-duplicated case-insensitively.
 */
object RecentTasksStore {

    private const val PREFS_NAME = "waylo_recents"
    private const val KEY_RECENTS = "recent_tasks"
    private const val MAX_RECENTS = 5

    /** Most recent task first. Empty on first launch or if nothing parses. */
    fun getRecents(context: Context): List<String> {
        val json = prefs(context).getString(KEY_RECENTS, null) ?: return emptyList()
        return try {
            val array = JSONArray(json)
            (0 until array.length()).map { array.getString(it) }
        } catch (e: Exception) {
            emptyList()
        }
    }

    /** Record [task] as the most recent, moving it to the front if already present. */
    fun addRecent(context: Context, task: String) {
        val trimmed = task.trim()
        if (trimmed.isEmpty()) return

        val updated = listOf(trimmed) +
            getRecents(context).filterNot { it.equals(trimmed, ignoreCase = true) }
        val capped = updated.take(MAX_RECENTS)

        val array = JSONArray()
        capped.forEach { array.put(it) }
        prefs(context).edit().putString(KEY_RECENTS, array.toString()).apply()
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
}
