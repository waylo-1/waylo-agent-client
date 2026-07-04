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
 * UNVERIFIED CONTRACT: [YOLO_DETECT_PATH] and the request/response JSON shape
 * below are a best-effort guess (no FastAPI spec was available at
 * implementation time) — see UNATTENDED_REPORT.md for what needs confirming
 * before this layer can actually fire in practice. Every failure mode (wrong
 * path → 404, wrong shape → parse exception, timeout, network error) resolves
 * to `null` from [detectAndMatch], so a bad guess here just means this layer
 * silently never contributes and the pipeline falls through to Gemini
 * Vision exactly as it did before this layer existed — it cannot make things
 * worse than they were.
 */
object YoloDetectionClient {

    private const val TAG = "WAYLO_DOT"

    /** One-line kill switch for this layer. */
    const val YOLO_LAYER_ENABLED = true

    private const val YOLO_BASE_URL = "http://13.127.137.249:8000"

    /** UNVERIFIED — confirm the real path against the FastAPI service. */
    private const val YOLO_DETECT_PATH = "/detect"

    private const val TIMEOUT_MS = 3000L

    /** Minimum score required for a match to be considered reliable (mirrors ElementFinder.MIN_SCORE). */
    private const val MIN_SCORE = 30

    private val client = OkHttpClient.Builder()
        .connectTimeout(3, TimeUnit.SECONDS)
        .readTimeout(3, TimeUnit.SECONDS)
        .writeTimeout(3, TimeUnit.SECONDS)
        .build()

    data class Detection(
        val label: String,
        val confidence: Float,
        val centerX: Int,
        val centerY: Int
    )

    /**
     * Detect on-screen elements in [bitmap] and return the best match for
     * [findDescription] (plus optional [alternateLabels]/[visualDescription]
     * hints from the step), using the same scoring shape as
     * [com.waylo.accessibility.ElementFinder]/[com.waylo.ocr.OcrAnalyzer]:
     * exact label match, partial/substring match, then small per-token and
     * per-alternate-label bonuses. Bounded to [TIMEOUT_MS] total. Returns null
     * on any failure, timeout, or if nothing clears [MIN_SCORE] — the caller
     * should fall through to Gemini Vision in that case.
     */
    suspend fun detectAndMatch(
        bitmap: Bitmap,
        findDescription: String,
        alternateLabels: List<String> = emptyList(),
        visualDescription: String? = null
    ): Detection? = withTimeoutOrNull(TIMEOUT_MS) {
        withContext(Dispatchers.IO) {
            try {
                val detections = requestDetections(bitmap)
                if (detections == null) {
                    Log.w(TAG, "YoloDetectionClient: no detections (bad response or non-2xx)")
                    return@withContext null
                }
                findBestMatch(detections, findDescription, alternateLabels, visualDescription)
            } catch (e: Exception) {
                Log.e(TAG, "YoloDetectionClient: detectAndMatch failed: ${e.message}", e)
                null
            }
        }
    }

    private fun requestDetections(bitmap: Bitmap): List<Detection>? {
        val baos = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, 70, baos)
        val base64 = Base64.encodeToString(baos.toByteArray(), Base64.NO_WRAP)

        // UNVERIFIED: assumed request shape {"image": "<base64 jpeg>"}.
        val body = JSONObject().apply { put("image", base64) }
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
        return parseDetections(responseBody)
    }

    /**
     * UNVERIFIED: assumed response shape
     * `{"detections":[{"label":"...","confidence":0.9,"box":{"x1":0,"y1":0,"x2":0,"y2":0}}]}`.
     * Any shape mismatch throws, which detectAndMatch catches and treats as a
     * miss (falls through to Gemini Vision) rather than crashing guidance.
     */
    private fun parseDetections(json: String): List<Detection> {
        val obj = JSONObject(json)
        val array = obj.optJSONArray("detections") ?: return emptyList()
        val result = mutableListOf<Detection>()
        for (i in 0 until array.length()) {
            val d = array.optJSONObject(i) ?: continue
            val box = d.optJSONObject("box") ?: continue
            val x1 = box.optInt("x1")
            val y1 = box.optInt("y1")
            val x2 = box.optInt("x2")
            val y2 = box.optInt("y2")
            val label = d.optString("label")
            if (label.isBlank()) continue
            result.add(
                Detection(
                    label = label,
                    confidence = d.optDouble("confidence", 0.0).toFloat(),
                    centerX = (x1 + x2) / 2,
                    centerY = (y1 + y2) / 2
                )
            )
        }
        return result
    }

    /** Same scoring shape as ElementFinder/OcrAnalyzer: exact +60, partial +35, per-token +15, per-alternate-label +15. */
    private fun findBestMatch(
        detections: List<Detection>,
        findDescription: String,
        alternateLabels: List<String>,
        visualDescription: String?
    ): Detection? {
        if (detections.isEmpty()) return null
        val desc = findDescription.lowercase().trim()
        val tokens = desc.split(Regex("\\s+")).filter { it.isNotBlank() }.toMutableList()
        if (!visualDescription.isNullOrBlank()) {
            tokens += visualDescription.lowercase().trim().split(Regex("\\s+")).filter { it.length > 2 }
        }
        val cleanedAlternates = alternateLabels.map { it.lowercase().trim() }.filter { it.isNotBlank() }

        var best: Detection? = null
        var bestScore = 0
        for (d in detections) {
            val label = d.label.lowercase().trim()
            if (label.isBlank()) continue
            var score = 0
            if (label == desc) {
                score += 60
            } else if (label.contains(desc) || desc.contains(label)) {
                score += 35
            }
            for (token in tokens) {
                if (label.contains(token)) score += 15
            }
            var altHits = 0
            for (alt in cleanedAlternates) {
                if (label == alt || label.contains(alt)) altHits++
            }
            if (altHits > 0) score += altHits * 15

            if (score > bestScore) {
                bestScore = score
                best = d
            }
        }

        return if (best != null && bestScore > MIN_SCORE) {
            Log.d(TAG, "YoloDetectionClient: best match '${best.label}' score=$bestScore")
            best
        } else {
            Log.d(TAG, "YoloDetectionClient: no match cleared MIN_SCORE for '$findDescription'")
            null
        }
    }
}
