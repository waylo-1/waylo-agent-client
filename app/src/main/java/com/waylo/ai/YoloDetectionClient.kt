package com.waylo.ai

import com.waylo.diagnostics.WayloVerify

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
 * does its own SigLIP matching server-side from `target_label`/
 * `step_instruction`/`screen_region` and returns, per element, `match_score`
 * (relative: which box means the target) and `match_conf` (absolute: is the
 * target on this screen). We pick by `match_score` and gate on `match_conf`
 * (see [selectBest]) — NOT by raw detector `confidence`, which ignores the
 * target. Only when the server applied no matching (no target_label) do we
 * fall back to confidence. `source`/`ax_class`/`caption` are captured on
 * [Detection] for logging/future use.
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

    /**
     * Presence gate for the SEMANTIC (SigLIP) path: the winning box's absolute
     * match_conf must clear this or we treat the target as not-on-screen and
     * fall through (to Gemini Vision / re-scan) rather than place on a
     * softmax-crowned false winner. Deliberately lenient to start — this layer
     * is only reached after the tree AND OCR already missed, so a best-effort
     * semantic pick beats escalating; the real value is tuned from the
     * match_conf figures the enriched YOLO_CALL log now records on device.
     */
    private const val MATCH_CONF_FLOOR = 0.10f

    /** The winning box's relative match_score must lead the runner-up by this, so a screen of near-tied crops doesn't get an arbitrary winner. */
    private const val MATCH_SCORE_MARGIN = 0.15f

    /**
     * Minimum gap (0-1) the top detection's confidence must lead the
     * runner-up by — mirrors [com.waylo.accessibility.ElementFinder.MIN_CONFIDENCE_GAP]'s
     * role: [MIN_CONFIDENCE] alone doesn't stop an arbitrary pick between two
     * similarly-confident boxes (e.g. the real target and a visually similar
     * icon nearby both clearing 0.5). 0.1 is proportionally equivalent to
     * ElementFinder's absolute gap of 10 on its own ~0-100 scoring scale,
     * scaled to this client's 0-1 confidence range (10% of the full range in
     * both cases). When there's only one detection, runnerUp defaults to 0,
     * so the gap check adds no extra burden beyond [MIN_CONFIDENCE] itself.
     */
    private const val MIN_CONFIDENCE_GAP = 0.1f

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
        /**
         * RELATIVE SigLIP match (softmax across boxes, sums to ~1): which box
         * MEANS the target. Null when the server didn't score (no target_label).
         * This — not [confidence] — is how we pick the target box.
         */
        val matchScore: Float? = null,
        /**
         * ABSOLUTE SigLIP match (calibrated sigmoid): is the target actually on
         * THIS screen. The server's own docs say callers MUST gate on this, or
         * a screen without the target still yields a confident (wrong) winner.
         */
        val matchConf: Float? = null,
        /** Tier-2 zero-shot caption for a textless icon ("search", "attach"), if the server assigned one. */
        val caption: String? = null,
        /** SHA-256 of the exact JPEG bytes sent for this detection — a lightweight reference for [com.waylo.ai.FailureReportClient.reportAutoSuccess] (never the raw image). */
        val screenshotHash: String? = null
    )

    /**
     * Detect the target element in [bitmap] and return its screen position if
     * the service's top-confidence element clears both [MIN_CONFIDENCE] and
     * [MIN_CONFIDENCE_GAP] over the runner-up (see [selectBest]).
     * [findDescription]/[instruction]/[screenRegion] are sent as
     * `target_label`/`step_instruction`/`screen_region` so the *service*
     * matches server-side — there is nothing to score client-side. Bounded to
     * [TIMEOUT_MS] total. Returns null on any failure, timeout, empty
     * element list, or a low/ambiguous confidence — the caller should fall
     * through to Gemini Vision (and, from there, GuidanceEngine's
     * speakTargetDescription()+re-scan path rather than ever guessing a
     * position) in that case.
     */
    suspend fun detectAndMatch(
        bitmap: Bitmap,
        findDescription: String,
        instruction: String? = null,
        screenRegion: String? = null,
        stepIndex: Int = -1
    ): Detection? = withTimeoutOrNull(TIMEOUT_MS) {
        withContext(Dispatchers.IO) {
            try {
                val elements = requestDetections(bitmap, findDescription, instruction, screenRegion, stepIndex)
                if (elements == null) {
                    Log.w(TAG, "YoloDetectionClient: no response (bad response or non-2xx)")
                    return@withContext null
                }
                selectBest(elements, stepIndex, httpStatus = 200)
            } catch (e: Exception) {
                Log.e(TAG, "YoloDetectionClient: detectAndMatch failed: ${e.message}", e)
                WayloVerify.d("YOLO_CALL | stepIndex=$stepIndex | httpStatus=-1 | boxCount=0 | topConfidence=0 | " +
                        "runnerUpConfidence=0 | gap=0 | confident=false | errorBody=${(e.message ?: "").take(120)}"
                )
                null
            }
        }
    }

    /**
     * Pure confidence-gated selection over a detection list — takes the
     * parsed elements directly so it's testable without a live network call,
     * same rationale as [com.waylo.accessibility.ElementFinder]'s score*
     * functions. Requires the top detection to both clear [MIN_CONFIDENCE]
     * and lead the runner-up by [MIN_CONFIDENCE_GAP]; returns null otherwise
     * (including when [elements] is empty). [stepIndex]/[httpStatus] are
     * logging-only context (defaulted so existing/test callers are
     * unaffected) — they don't influence the selection itself.
     */
    internal fun selectBest(elements: List<Detection>, stepIndex: Int = -1, httpStatus: Int = 200): Detection? {
        // PREFER the server's SEMANTIC match. match_score says which box MEANS
        // the target; match_conf says whether the target is even on this
        // screen. Picking by raw detector `confidence` (as this did before)
        // ignores the target entirely and lands on whatever box the detector
        // is surest is *a* UI element — the root cause of "it can't find the
        // send/trash icon". Only fall back to confidence when the server did
        // NOT score (no target_label — the Set-of-Mark captioning path).
        val matchScored = elements.filter { it.matchScore != null }
        if (matchScored.isNotEmpty()) {
            val bySem = matchScored.sortedByDescending { it.matchScore ?: -1f }
            val best = bySem.first()
            val runnerUp = bySem.getOrNull(1)?.matchScore ?: 0f
            val bestScore = best.matchScore ?: 0f
            val bestConf = best.matchConf ?: 0f
            val margin = bestScore - runnerUp
            val confident = bestConf >= MATCH_CONF_FLOOR && margin >= MATCH_SCORE_MARGIN
            WayloVerify.d("YOLO_CALL | stepIndex=$stepIndex | httpStatus=$httpStatus | boxCount=${elements.size} | " +
                    "matchScore=$bestScore | runnerUpMatchScore=$runnerUp | matchConf=$bestConf | scoreMargin=$margin | " +
                    "caption=${best.caption ?: ""} | detectorConfidence=${best.confidence} | confident=$confident | errorBody="
            )
            return if (confident) {
                Log.d(TAG, "YoloDetectionClient: semantic pick matchScore=$bestScore conf=$bestConf at (${best.centerX},${best.centerY})")
                best
            } else {
                Log.d(TAG, "YoloDetectionClient: semantic match below floor (conf=$bestConf<$MATCH_CONF_FLOOR or margin=$margin<$MATCH_SCORE_MARGIN)")
                null
            }
        }

        // Legacy path: server applied no semantic matching → detector confidence.
        val sorted = elements.sortedByDescending { it.confidence }
        val best = sorted.firstOrNull()
        val runnerUp = sorted.getOrNull(1)?.confidence ?: 0f
        val gap = (best?.confidence ?: 0f) - runnerUp
        val confident = best != null && best.confidence >= MIN_CONFIDENCE && gap >= MIN_CONFIDENCE_GAP
        WayloVerify.d("YOLO_CALL | stepIndex=$stepIndex | httpStatus=$httpStatus | boxCount=${elements.size} | " +
                "topConfidence=${best?.confidence ?: 0f} | runnerUpConfidence=$runnerUp | gap=$gap | " +
                "confident=$confident | errorBody="
        )
        return when {
            best == null -> {
                Log.d(TAG, "YoloDetectionClient: elements list empty")
                null
            }
            confident -> {
                Log.d(TAG, "YoloDetectionClient: best confidence=${best.confidence} runnerUp=$runnerUp at (${best.centerX},${best.centerY})")
                best
            }
            else -> {
                Log.d(
                    TAG,
                    "YoloDetectionClient: best confidence=${best.confidence} runnerUp=$runnerUp " +
                        "below threshold (floor=$MIN_CONFIDENCE, gap=$MIN_CONFIDENCE_GAP)"
                )
                null
            }
        }
    }

    private fun requestDetections(
        bitmap: Bitmap,
        targetLabel: String,
        stepInstruction: String?,
        screenRegion: String?,
        stepIndex: Int = -1
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
            WayloVerify.d("YOLO_CALL | stepIndex=$stepIndex | httpStatus=${response.code} | boxCount=0 | topConfidence=0 | " +
                    "runnerUpConfidence=0 | gap=0 | confident=false | errorBody=${(responseBody ?: "").take(120)}"
            )
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
            val matchScore = e.optDouble("match_score", Double.NaN).let { if (it.isNaN()) null else it.toFloat() }
            val matchConf = e.optDouble("match_conf", Double.NaN).let { if (it.isNaN()) null else it.toFloat() }
            val caption = e.optString("caption").takeIf { it.isNotBlank() }
            Log.d(TAG, "YoloDetectionClient: element $i source=$source ax_class=$axClass confidence=${e.optDouble("confidence", 0.0)} matchScore=$matchScore matchConf=$matchConf caption=$caption")

            result.add(
                Detection(
                    centerX = cx.toInt(),
                    centerY = cy.toInt(),
                    confidence = e.optDouble("confidence", 0.0).toFloat(),
                    source = source,
                    axClass = axClass,
                    matchScore = matchScore,
                    matchConf = matchConf,
                    caption = caption,
                    screenshotHash = screenshotHash
                )
            )
        }
        return result
    }
}
