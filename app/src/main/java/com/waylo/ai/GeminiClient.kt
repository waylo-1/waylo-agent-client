// HTTP client for the Waylo backend (/plan).
// The Gemini API key lives only on the backend — never in the Android app.
package com.waylo.ai

import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import com.waylo.service.WayloGuidanceService
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * Talks to the deployed Waylo backend, which in turn calls Gemini. The app
 * never holds the Gemini API key directly.
 *
 * Backend: http://13.127.137.249:3000
 */
object GeminiClient {

    private const val BACKEND_URL = "http://13.127.137.249:3000"

    private val client = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .build()

    /**
     * POST /plan with the user's task. Retries up to [maxRetries] times on
     * transient backend errors (5xx / empty responses / network exceptions),
     * with a short delay between attempts. Returns the parsed plan, or an
     * empty plan (no steps) if every attempt fails.
     */
    suspend fun getPlan(task: String): Plan = withContext(Dispatchers.IO) {
        val maxRetries = 3
        val retryDelayMs = 2000L

        repeat(maxRetries) { attempt ->
            Log.e("WAYLO_DOT", "GeminiClient: attempt ${attempt + 1}/$maxRetries for task: $task")
            try {
                val jsonBody = JSONObject().apply {
                    put("task", task)
                    put("language", "en")
                }.toString()

                val requestBody = jsonBody.toRequestBody("application/json".toMediaType())
                val request = Request.Builder()
                    .url("$BACKEND_URL/plan")
                    .post(requestBody)
                    .addHeader("Content-Type", "application/json")
                    .build()

                val response = client.newCall(request).execute()
                val responseBody = response.body?.string() ?: ""
                Log.e("WAYLO_DOT", "GeminiClient: code=${response.code} body=$responseBody")

                if (response.isSuccessful) {
                    val plan = PlanParser.parse(responseBody)
                    if (plan != null && plan.steps.isNotEmpty()) return@withContext plan
                }

                // 500 or empty — tell the user and wait before retrying.
                if (attempt < maxRetries - 1) {
                    Log.e("WAYLO_DOT", "GeminiClient: retrying in ${retryDelayMs}ms...")
                    // Speak feedback on first failure only.
                    if (attempt == 0) {
                        withContext(Dispatchers.Main) {
                            WayloGuidanceService.instance?.speaker
                                ?.speak("Taking a moment, please wait...")
                        }
                    }
                    delay(retryDelayMs)
                }
            } catch (e: Exception) {
                Log.e("WAYLO_DOT", "GeminiClient: exception on attempt ${attempt + 1}: ${e.message}")
                if (attempt < maxRetries - 1) delay(retryDelayMs)
            }
        }

        Log.e("WAYLO_DOT", "GeminiClient: all $maxRetries attempts failed")
        return@withContext Plan(appPackage = null, appName = null, steps = emptyList())
    }
}
