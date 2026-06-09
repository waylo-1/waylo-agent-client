// Retrofit client for the Waylo backend (/plan, /guide).
// The Gemini API key lives only on the backend — never in the Android app.
package com.waylo.ai

import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import retrofit2.Retrofit
import retrofit2.converter.gson.GsonConverterFactory
import retrofit2.http.Body
import retrofit2.http.POST
import java.util.concurrent.TimeUnit

/**
 * Talks to the Waylo backend, which in turn calls Gemini. The app never holds
 * the Gemini API key directly.
 *
 * Backend: https://backendinitial-production.up.railway.app
 */
object GeminiClient {

    private const val TAG = "Waylo"
    private const val BASE_URL = "https://backendinitial-production.up.railway.app/"

    // ---- Wire models matching the backend JSON ----

    private data class PlanRequest(val task: String)

    private data class PlanResponse(
        val success: Boolean = false,
        val language: String? = null,
        val steps: List<StepDto>? = null,
        val totalSteps: Int? = null
    )

    private data class StepDto(
        val stepNumber: Int? = null,
        val instruction: String? = null,
        val findDescription: String? = null,
        val appName: String? = null,
        val expectedScreenTitle: String? = null
    )

    private interface PlanApi {
        @POST("plan")
        suspend fun plan(@Body body: PlanRequest): PlanResponse
    }

    // Gemini calls can take several seconds — give generous read timeouts.
    private val http: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .writeTimeout(30, TimeUnit.SECONDS)
            .build()
    }

    private val api: PlanApi by lazy {
        Retrofit.Builder()
            .baseUrl(BASE_URL)
            .client(http)
            .addConverterFactory(GsonConverterFactory.create())
            .build()
            .create(PlanApi::class.java)
    }

    /**
     * POST /plan with the user's task. Returns the parsed steps, or an empty
     * list if the backend reports failure or returns nothing.
     */
    suspend fun requestPlan(task: String): List<Step> = withContext(Dispatchers.IO) {
        Log.d(TAG, "GeminiClient: requesting plan for task='$task'")
        try {
            val response = api.plan(PlanRequest(task))
            val dtos = response.steps.orEmpty()
            Log.d(TAG, "GeminiClient: backend returned success=${response.success}, ${dtos.size} steps.")

            dtos.mapIndexed { i, dto ->
                Step(
                    index = dto.stepNumber ?: (i + 1),
                    instruction = dto.instruction.orEmpty(),
                    findDescription = dto.findDescription.orEmpty()
                )
            }.filter { it.findDescription.isNotBlank() }
        } catch (e: Exception) {
            Log.e(TAG, "GeminiClient: plan request failed.", e)
            throw e
        }
    }
}
