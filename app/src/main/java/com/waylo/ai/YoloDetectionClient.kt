package com.waylo.ai

import android.graphics.Bitmap
import android.util.Base64
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.concurrent.TimeUnit

/**
 * On-EC2 YOLO object detector — sits between ML Kit OCR and Gemini Vision in
 * the fallback chain (see [com.waylo.guidance.FallbackHandler]): cheaper and
 * faster than a Gemini Vision call, tried first when OCR misses.
 *
 * Contract re-verified live against `GET /openapi.json` on the deployed
 * service (`POST /detect`, `DetectRequest`/`DetectResponse`/`DetectedElement`
 * — field names match exactly: `screenshot_b64`/`target_label`/
 * `step_instruction`/`screen_region` in, `elements`/`omni_count`/
 * `macos_count`/`merged_count` out, each element carrying
 * `x`/`y`/`w`/`h`/`cx`/`cy`/`confidence`/`source`/`ax_class`). The service
 * does its own matching server-side from `target_label`/`step_instruction`/
 * `screen_region` — no label/text field to score against client-side (unlike
 * ElementFinder/OcrAnalyzer) — so we just take the highest-confidence element
 * and accept it if it clears [MIN_CONFIDENCE]. `source`/`ax_class` are
 * captured on [Detection] (previously silently discarded) for logging/
 * future use, not currently used to pick between candidates.
 *
 * What's still genuinely unverified: whether x/y/w/h/cx/cy are normalized
 * (0-1) or pixel values — the schema doesn't declare a range, hence the
 * per-element <=1.0 heuristic in [parseElements].
 */
object YoloDetectionClient {

    private const val TAG = "WAYLO_DOT"

    /** One-line kill switch for this layer. */
    const val YOLO_LAYER_ENABLED = true

    private const val YOLO_BASE_URL = "http://13.127.137.249:8000"
    private const val YOLO_DETECT_PATH = "/detect"

    private const val TIMEOUT_MS = 3000L

    /** Minimum confidence (0-1) required to trust the top detection. */
    private const val MIN_CONFIDENCE = 0.5f

    private val client = OkHttpClient.Builder()
        .connectTimeout(3, TimeUnit.SECONDS)
        .readTimeout(3, TimeUnit.SECONDS)
        .writeTimeout(3, TimeUnit.SECONDS)
        .build()

    data class Detection(
        val centerX: Int,
        val centerY: Int,
        val confidence: Float,
        /** Which detector produced this element ("omni"/"macos"/merged, per the service's *_count fields) — verified present in DetectedElement, previously discarded. */
        val source: String? = null,
        /** Server-side semantic class for this element (e.g. an icon/image/button classification), if the service assigned one — previously discarded. */
        val axClass: String? = null,
        /** SHA-256 of the exact JPEG bytes sent for this detection — a lightweight reference for [com.waylo.ai.FailureReportClient.reportAutoSuccess] (never the raw image). */
        val screenshotHash: String? = null
    )

    /**
     * Detect the target element in [bitmap] and return its screen position if
     * the service's top-confidence element clears [MIN_CONFIDENCE].
     * [findDescription]/[instruction]/[screenRegion] are sent as
     * `target_label`/`step_instruction`/`screen_region` so the *service*
     * matches server-side — there is nothing to score client-side. Bounded to
     * [TIMEOUT_MS] total. Returns null on any failure, timeout, empty
     * element list, or low confidence — the caller should fall through to
     * Gemini Vision in that case.
     */
    suspend fun detectAndMatch(
        bitmap: Bitmap,
        findDescription: String,
        instruction: String? = null,
        screenRegion: String? = null
    ): Detection? = withTimeoutOrNull(TIMEOUT_MS) {
        withContext(Dispatchers.IO) {
            try {
                val elements = requestDetections(bitmap, findDescription, instruction, screenRegion)
                if (elements == null) {
                    Log.w(TAG, "YoloDetectionClient: no response (bad response or non-2xx)")
                    return@withContext null
                }
                val best = elements.maxByOrNull { it.confidence }
                when {
                    best == null -> {
                        Log.d(TAG, "YoloDetectionClient: elements list empty")
                        null
                    }
                    best.confidence >= MIN_CONFIDENCE -> {
                        Log.d(TAG, "YoloDetectionClient: best confidence=${best.confidence} at (${best.centerX},${best.centerY})")
                        best
                    }
                    else -> {
                        Log.d(TAG, "YoloDetectionClient: best confidence=${best.confidence} below threshold $MIN_CONFIDENCE")
                        null
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "YoloDetectionClient: detectAndMatch failed: ${e.message}", e)
                null
            }
        }
    }

    private fun requestDetections(
        bitmap: Bitmap,
        targetLabel: String,
        stepInstruction: String?,
        screenRegion: String?
    ): List<Detection>? {
        val baos = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, 70, baos)
        val jpegBytes = baos.toByteArray()
        val base64 = Base64.encodeToString(jpegBytes, Base64.NO_WRAP)
        // Hash of the exact bytes sent — a cheap, non-identifying reference
        // for success-pair logging (see Detection.screenshotHash) so we never
        // need to store/re-upload the actual image for a routine success.
        val screenshotHash = sha256Hex(jpegBytes)

        val body = JSONObject().apply {
            put("screenshot_b64", base64)
            if (targetLabel.isNotBlank()) put("target_label", targetLabel)
            if (!stepInstruction.isNullOrBlank()) put("step_instruction", stepInstruction)
            if (!screenRegion.isNullOrBlank()) put("screen_region", screenRegion)
        }
        val requestBody = body.toString().toRequestBody("application/json".toMediaType())
        val request = Request.Builder()
            .url("$YOLO_BASE_URL$YOLO_DETECT_PATH")
            .post(requestBody)
            .build()

        val response = client.newCall(request).execute()
        val responseBody = response.body?.string()
        if (!response.isSuccessful || responseBody == null) {
            Log.w(TAG, "YoloDetectionClient: HTTP ${response.code}")
            return null
        }
        // The screenshot we send is exactly bitmap.width x bitmap.height, so
        // that's also the right frame to de-normalize into (matches whatever
        // resolution OverlayManager expects for this bitmap's coordinates).
        return parseElements(responseBody, bitmap.width, bitmap.height, screenshotHash)
    }

    private fun sha256Hex(bytes: ByteArray): String =
        java.security.MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    /**
     * Parses `DetectResponse.elements`. Coordinates may be normalized (0-1)
     * or pixel-based — the schema doesn't say which. Per-element heuristic:
     * if x, y, w, h are all <= 1.0, treat that element as normalized and
     * scale cx/cy by [bitmapWidth]/[bitmapHeight]; otherwise treat cx/cy as
     * already being pixels. Logs which branch was taken.
     */
    private fun parseElements(json: String, bitmapWidth: Int, bitmapHeight: Int, screenshotHash: String): List<Detection> {
        val obj = JSONObject(json)
        val array = obj.optJSONArray("elements") ?: return emptyList()
        Log.d(
            TAG,
            "YoloDetectionClient: elements=${array.length()} omni_count=${obj.optInt("omni_count")} " +
                "macos_count=${obj.optInt("macos_count")} merged_count=${obj.optInt("merged_count")}"
        )

        val result = mutableListOf<Detection>()
        for (i in 0 until array.length()) {
            val e = array.optJSONObject(i) ?: continue
            val x = e.optDouble("x", Double.NaN)
            val y = e.optDouble("y", Double.NaN)
            val w = e.optDouble("w", Double.NaN)
            val h = e.optDouble("h", Double.NaN)
            var cx = e.optDouble("cx", Double.NaN)
            var cy = e.optDouble("cy", Double.NaN)
            if (cx.isNaN() || cy.isNaN()) continue

            val normalized = listOf(x, y, w, h).all { !it.isNaN() && it <= 1.0 }
            if (normalized) {
                Log.d(TAG, "YoloDetectionClient: element $i is normalized (x=$x y=$y w=$w h=$h) -> scaling by ${bitmapWidth}x$bitmapHeight")
                cx *= bitmapWidth
                cy *= bitmapHeight
            } else {
                Log.d(TAG, "YoloDetectionClient: element $i is pixel coordinates (x=$x y=$y w=$w h=$h)")
            }

            val source = e.optString("source").takeIf { it.isNotBlank() }
            val axClass = e.optString("ax_class").takeIf { it.isNotBlank() }
            Log.d(TAG, "YoloDetectionClient: element $i source=$source ax_class=$axClass confidence=${e.optDouble("confidence", 0.0)}")

            result.add(
                Detection(
                    centerX = cx.toInt(),
                    centerY = cy.toInt(),
                    confidence = e.optDouble("confidence", 0.0).toFloat(),
                    source = source,
                    axClass = axClass,
                    screenshotHash = screenshotHash
                )
            )
        }
        return result
    }
}
