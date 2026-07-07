package com.waylo.ai

import android.graphics.Rect
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * Client for `POST /failure` — the backend's `detection_failures` table,
 * which now stores three event kinds (see the backend's
 * `migrations/add_correction_fields.sql` and `routes/failure.js`):
 *
 *  - `auto_miss` (not sent from here — the original on-device-detection-
 *    missed path; see FallbackHandler/GuidanceEngine's existing flow).
 *  - `user_correction` — the volume-button-double-press correction flow
 *    (`com.waylo.correction.CorrectionFlow`): what the user said went wrong,
 *    and/or the node they tapped as the actually-correct target.
 *  - `auto_success` — an opt-in (see [YoloDetectionClient]'s success-logging
 *    call site) log of a successful YOLO detection as a training pair.
 *
 * Field names here are chosen to match `routes/failure.js`'s destructured
 * request body exactly (camelCase over the wire; the route maps to the
 * snake_case DB columns).
 */
object FailureReportClient {

    private const val TAG = "WAYLO_DOT"
    private const val BASE_URL = "http://13.127.137.249:3000"

    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(10, TimeUnit.SECONDS)
        .build()

    /** Mirrors routes/failure.js's `correctedTarget` shape exactly. */
    data class CorrectedTarget(
        val bounds: Rect?,
        val text: String?,
        val contentDescription: String?,
        val viewId: String?
    )

    /** Mirrors routes/failure.js's `chosenBox` shape exactly. */
    data class ChosenBox(
        val centerX: Int,
        val centerY: Int,
        val confidence: Float,
        val source: String?,
        val axClass: String?
    )

    /** POST a user_correction event. Fire-and-forget from the caller's perspective — failures are logged, not thrown. */
    suspend fun reportUserCorrection(
        sessionId: String,
        taskDescription: String?,
        stepNumber: Int?,
        findDescription: String,
        correctionText: String?,
        correctedTarget: CorrectedTarget?,
        currentPackage: String?,
        currentActivity: String?
    ) {
        val body = JSONObject().apply {
            put("sessionId", sessionId)
            put("source", "user_correction")
            put("findDescription", findDescription)
            taskDescription?.let { put("taskDescription", it) }
            stepNumber?.let { put("stepNumber", it) }
            correctionText?.let { put("correctionText", it) }
            currentPackage?.let { put("currentPackage", it) }
            currentActivity?.let { put("currentActivity", it) }
            correctedTarget?.let { put("correctedTarget", it.toJson()) }
        }
        post(body, "reportUserCorrection")
    }

    /** POST an auto_success event (a successful YOLO detection, logged as a training pair). Fire-and-forget. */
    suspend fun reportAutoSuccess(
        sessionId: String,
        stepNumber: Int?,
        findDescription: String,
        targetPackage: String?,
        chosenBox: ChosenBox,
        screenshotHash: String?
    ) {
        val body = JSONObject().apply {
            put("sessionId", sessionId)
            put("source", "auto_success")
            put("findDescription", findDescription)
            stepNumber?.let { put("stepNumber", it) }
            targetPackage?.let { put("targetPackage", it) }
            screenshotHash?.let { put("screenshotHash", it) }
            put("chosenBox", chosenBox.toJson())
        }
        post(body, "reportAutoSuccess")
    }

    /** `internal` (not `private`) so the payload shape is directly unit-testable against routes/failure.js's expected field names. */
    internal fun CorrectedTarget.toJson(): JSONObject = JSONObject().apply {
        bounds?.let {
            put(
                "bounds",
                JSONObject().apply {
                    put("left", it.left); put("top", it.top); put("right", it.right); put("bottom", it.bottom)
                }
            )
        }
        text?.let { put("text", it) }
        contentDescription?.let { put("contentDescription", it) }
        viewId?.let { put("viewId", it) }
    }

    /** `internal` for the same reason as [CorrectedTarget.toJson]. */
    internal fun ChosenBox.toJson(): JSONObject = JSONObject().apply {
        put("centerX", centerX)
        put("centerY", centerY)
        put("confidence", confidence)
        source?.let { put("source", it) }
        axClass?.let { put("ax_class", it) }
    }

    private suspend fun post(body: JSONObject, callerTag: String) = withContext(Dispatchers.IO) {
        try {
            val requestBody = body.toString().toRequestBody("application/json".toMediaType())
            val request = Request.Builder()
                .url("$BASE_URL/failure")
                .post(requestBody)
                .build()
            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) {
                    Log.w(TAG, "FailureReportClient.$callerTag: HTTP ${response.code} ${response.body?.string()}")
                } else {
                    Log.d(TAG, "FailureReportClient.$callerTag: reported successfully")
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "FailureReportClient.$callerTag: failed (${e.message}) — dropping, not training-critical")
        }
    }
}
