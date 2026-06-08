// TODO: Day 9 — implement Retrofit calls to the backend (/plan, /guide).
// The Gemini API key lives only on the backend — never in the Android app.
package com.sahayak.ai

/**
 * Talks to the Sahayak backend, which in turn calls Gemini. The app never holds
 * the Gemini API key directly.
 */
object GeminiClient {

    /** TODO: Day 9 — POST /plan with the task, return parsed steps. */
    suspend fun requestPlan(task: String): List<Step> {
        // TODO: Retrofit call to backend POST /plan on Dispatchers.IO.
        return emptyList()
    }
}
