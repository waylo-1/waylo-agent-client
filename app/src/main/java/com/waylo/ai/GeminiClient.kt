// HTTP client for the Waylo backend (/plan).
// The Gemini API key lives only on the backend — never in the Android app.
package com.waylo.ai

import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import com.waylo.guidance.DetectionFailure
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
 * Backend: https://backendinitial-production.up.railway.app
 */
object GeminiClient {

    private const val BACKEND_URL = "https://backendinitial-production.up.railway.app"

    private val client = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .build()

    /**
     * POST /plan with the user's task. Retries up to [maxRetries] times on
     * transient backend errors (5xx / empty responses / network exceptions),
     * with a short delay between attempts. Returns the parsed steps, or an
     * empty list if every attempt fails.
     */
    suspend fun getPlan(task: String): List<Step> = withContext(Dispatchers.IO) {
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
                    val steps = parseSteps(responseBody)
                    if (steps.isNotEmpty()) return@withContext steps
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
        return@withContext emptyList()
    }

    /**
     * Report a detection failure to the backend `/failure` endpoint so it can be
     * stored for future YOLO training. Fire-and-forget: the response is ignored
     * and any error is swallowed by the caller ([FailureLogger]).
     */
    suspend fun reportFailure(failure: DetectionFailure) {
        val body = JSONObject().apply {
            put("sessionId", failure.sessionId)
            put("taskDescription", failure.taskDescription)
            put("stepNumber", failure.stepNumber)
            put("findDescription", failure.findDescription)
            put("elementType", failure.elementType)
            put("screenRegion", failure.screenRegion)
            put("visualDescription", failure.visualDescription)
            put("targetPackage", failure.targetPackage)
            put("layerReached", failure.layerReached)
            put("screenshotBase64", failure.screenshotBase64)
            put("screenWidth", failure.screenWidth)
            put("screenHeight", failure.screenHeight)
            put("timestamp", failure.timestamp)
        }
        // POST to /failure — fire and forget, ignore response.
        makePostRequest("/failure", body)
    }

    /** Minimal POST helper for fire-and-forget backend calls. */
    private suspend fun makePostRequest(path: String, body: JSONObject): Unit =
        withContext(Dispatchers.IO) {
            try {
                val requestBody = body.toString().toRequestBody("application/json".toMediaType())
                val request = Request.Builder()
                    .url("$BACKEND_URL$path")
                    .post(requestBody)
                    .addHeader("Content-Type", "application/json")
                    .build()
                client.newCall(request).execute().use { response ->
                    Log.d("WAYLO_DOT", "POST $path → ${response.code}")
                }
            } catch (e: Exception) {
                Log.w("WAYLO_DOT", "POST $path failed: ${e.message}")
            }
        }

    /**
     * POST /plan and parse the enriched response into a [PlanParser.Plan]
     * (appPackage + appName + rich [com.waylo.guidance.StepMetadata]). Retries
     * like [getPlan]. Returns an empty plan if every attempt fails.
     */
    suspend fun getEnrichedPlan(task: String): PlanParser.Plan = withContext(Dispatchers.IO) {
        val maxRetries = 3
        val retryDelayMs = 2000L

        repeat(maxRetries) { attempt ->
            Log.e("WAYLO_DOT", "GeminiClient: enriched attempt ${attempt + 1}/$maxRetries for task: $task")
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
                Log.e("WAYLO_DOT", "GeminiClient(enriched): code=${response.code} body=${responseBody.take(300)}")

                if (response.isSuccessful) {
                    val plan = PlanParser.parse(responseBody)
                    if (plan.steps.isNotEmpty()) return@withContext plan
                }

                if (attempt < maxRetries - 1) {
                    if (attempt == 0) {
                        withContext(Dispatchers.Main) {
                            WayloGuidanceService.instance?.speaker
                                ?.speak("Taking a moment, please wait...")
                        }
                    }
                    delay(retryDelayMs)
                }
            } catch (e: Exception) {
                Log.e("WAYLO_DOT", "GeminiClient(enriched): exception attempt ${attempt + 1}: ${e.message}")
                if (attempt < maxRetries - 1) delay(retryDelayMs)
            }
        }

        Log.e("WAYLO_DOT", "GeminiClient(enriched): all $maxRetries attempts failed")
        return@withContext PlanParser.Plan("", "", emptyList())
    }

    private fun parseSteps(json: String): List<Step> {
        return try {
            val obj = JSONObject(json)
            if (!obj.optBoolean("success", false)) {
                Log.e("WAYLO_DOT", "parseSteps: backend returned success=false: $json")
                return emptyList()
            }
            val stepsArray = obj.getJSONArray("steps")
            val result = mutableListOf<Step>()
            for (i in 0 until stepsArray.length()) {
                val s = stepsArray.getJSONObject(i)
                result.add(
                    Step(
                        index = s.optInt("stepNumber", i + 1),
                        instruction = s.optString("instruction", "Follow the dot"),
                        findDescription = s.optString("findDescription", "")
                    )
                )
            }
            Log.e("WAYLO_DOT", "parseSteps: got ${result.size} steps")
            result.forEach { Log.e("WAYLO_DOT", "  Step ${it.index}: ${it.instruction} | find: ${it.findDescription}") }
            result
        } catch (e: Exception) {
            Log.e("WAYLO_DOT", "parseSteps FAILED: ${e.message} | json: $json", e)
            emptyList()
        }
    }
}
