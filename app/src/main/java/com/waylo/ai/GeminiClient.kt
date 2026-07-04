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

    /** Sentinel [Plan.error] value meaning "no response at all" (thrown exception, not a backend error body). */
    const val NETWORK_ERROR = "network_error"

    /**
     * POST /plan with the user's task. Retries up to [maxRetries] times on
     * transient backend errors (5xx / empty responses / network exceptions),
     * with a short delay between attempts. Returns the parsed plan; on total
     * failure, returns the last error-carrying [Plan] seen (backend text) or,
     * if every attempt threw before getting a response, a [Plan] flagged with
     * [NETWORK_ERROR].
     */
    suspend fun getPlan(task: String): Plan = withContext(Dispatchers.IO) {
        val maxRetries = 3
        val retryDelayMs = 2000L
        var lastErrorPlan: Plan? = null

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

                // Parse regardless of HTTP status: the backend sends a JSON
                // error body ({"success":false,"error":...,"details":...}) on
                // failures too, and we want that text for the user message.
                val plan = PlanParser.parse(responseBody)
                if (plan != null) {
                    if (plan.steps.isNotEmpty()) return@withContext plan
                    lastErrorPlan = plan
                } else {
                    lastErrorPlan = Plan(
                        appPackage = null,
                        appName = null,
                        steps = emptyList(),
                        error = "bad_response",
                        errorDetail = "HTTP ${response.code}: ${responseBody.take(200)}"
                    )
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
                Log.e("WAYLO_DOT", "GeminiClient: exception on attempt ${attempt + 1}: ${e.message}", e)
                lastErrorPlan = Plan(
                    appPackage = null,
                    appName = null,
                    steps = emptyList(),
                    error = NETWORK_ERROR,
                    errorDetail = e.message
                )
                if (attempt < maxRetries - 1) delay(retryDelayMs)
            }
        }

        Log.e("WAYLO_DOT", "GeminiClient: all $maxRetries attempts failed")
        return@withContext lastErrorPlan ?: Plan(
            appPackage = null,
            appName = null,
            steps = emptyList(),
            error = NETWORK_ERROR,
            errorDetail = "No response from backend"
        )
    }
}
