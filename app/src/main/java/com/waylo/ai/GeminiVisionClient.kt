package com.waylo.ai

import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * GeminiVisionClient — Layer 3 element finder + troubleshooter.
 *
 * Two modes, both POSTing a Base64 JPEG screenshot to the backend `/vision`
 * endpoint (which keeps the Gemini key server-side):
 *
 *  - LOCATE: "I expect element X. Where is it?" → [LocateResult] with pixel (x,y).
 *  - TROUBLESHOOT: "X is missing — what should the user do?" → [TroubleshootResult]
 *    with recovery [Step]s that splice into the remaining plan.
 *
 * Reuses the shared [Step] model from PlanParser.kt.
 */
object GeminiVisionClient {

    private const val TAG = "WAYLO_DOT"
    private const val BACKEND_URL = "http://13.127.137.249:3000/vision"
    private const val MAX_RETRIES = 2
    private const val RETRY_DELAY_MS = 3000L

    private val client = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(45, TimeUnit.SECONDS) // Vision calls are slower.
        .writeTimeout(30, TimeUnit.SECONDS)
        .build()

    data class LocateResult(
        val found: Boolean,
        val x: Int,
        val y: Int,
        val updatedFindDescription: String,
        val instruction: String
    )

    data class TroubleshootResult(
        val recoverable: Boolean,
        val explanation: String,
        val newSteps: List<Step>
    )

    /** Ask Gemini Vision to locate an expected element. Null on total failure. */
    suspend fun locate(
        screenshotBase64: String,
        task: String,
        currentStepIndex: Int,
        totalSteps: Int,
        findDescription: String,
        language: String = "en"
    ): LocateResult? = withContext(Dispatchers.IO) {
        val body = JSONObject().apply {
            put("mode", "locate")
            put("screenshotBase64", screenshotBase64)
            put("task", task)
            put("currentStepIndex", currentStepIndex)
            put("totalSteps", totalSteps)
            put("findDescription", findDescription)
            put("language", language)
        }

        val response = callBackendWithRetry(body) ?: return@withContext null
        return@withContext try {
            LocateResult(
                found = response.optBoolean("found", false),
                x = response.optInt("x", 0),
                y = response.optInt("y", 0),
                updatedFindDescription = response.optString("updatedFindDescription", findDescription),
                instruction = response.optString("instruction", "")
            )
        } catch (e: Exception) {
            Log.e(TAG, "Failed to parse locate response", e)
            null
        }
    }

    /**
     * Ask Gemini Vision to troubleshoot a missing element and generate recovery
     * steps to continue the task. Null on total failure.
     */
    suspend fun troubleshoot(
        screenshotBase64: String,
        task: String,
        currentStepIndex: Int,
        totalSteps: Int,
        findDescription: String,
        language: String = "en"
    ): TroubleshootResult? = withContext(Dispatchers.IO) {
        val body = JSONObject().apply {
            put("mode", "troubleshoot")
            put("screenshotBase64", screenshotBase64)
            put("task", task)
            put("currentStepIndex", currentStepIndex)
            put("totalSteps", totalSteps)
            put("findDescription", findDescription)
            put("language", language)
        }

        val response = callBackendWithRetry(body) ?: return@withContext null
        return@withContext try {
            val stepsArray = response.optJSONArray("newSteps")
            val steps = mutableListOf<Step>()
            if (stepsArray != null) {
                for (i in 0 until stepsArray.length()) {
                    val s = stepsArray.getJSONObject(i)
                    steps.add(
                        Step(
                            index = s.optInt("stepNumber", i + 1),
                            instruction = s.optString("instruction", ""),
                            findDescription = s.optString("findDescription", "")
                        )
                    )
                }
            }
            TroubleshootResult(
                recoverable = response.optBoolean("recoverable", false),
                explanation = response.optString("explanation", ""),
                newSteps = steps
            )
        } catch (e: Exception) {
            Log.e(TAG, "Failed to parse troubleshoot response", e)
            null
        }
    }

    private suspend fun callBackendWithRetry(body: JSONObject): JSONObject? {
        repeat(MAX_RETRIES) { attempt ->
            try {
                val requestBody = body.toString().toRequestBody("application/json".toMediaType())
                val request = Request.Builder()
                    .url(BACKEND_URL)
                    .post(requestBody)
                    .build()

                val response = client.newCall(request).execute()
                val responseBody = response.body?.string()
                if (response.isSuccessful && responseBody != null) {
                    Log.d(TAG, "Vision response: ${responseBody.take(200)}")
                    return JSONObject(responseBody)
                } else {
                    Log.w(TAG, "Vision call failed: ${response.code} attempt=${attempt + 1}")
                }
            } catch (e: Exception) {
                Log.e(TAG, "Vision call exception attempt=${attempt + 1}", e)
            }
            if (attempt < MAX_RETRIES - 1) delay(RETRY_DELAY_MS)
        }
        return null
    }
}
