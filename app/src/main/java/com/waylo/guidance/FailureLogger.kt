package com.waylo.guidance

import android.util.Log
import com.waylo.ai.GeminiClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * Fire-and-forget logger for detection failures.
 *
 * Called from [FallbackHandler] when all local layers (L0, L1, L2) miss, right
 * before escalating to the vision fallback. Sends the failure to the backend
 * asynchronously and never blocks — or crashes — the guidance flow.
 */
object FailureLogger {

    private const val TAG = "WayloFailureLogger"

    /**
     * Report [failure] to the backend on a background coroutine. The guidance
     * flow should continue to the vision fallback immediately after calling this.
     */
    fun logFailure(failure: DetectionFailure) {
        CoroutineScope(Dispatchers.IO).launch {
            try {
                GeminiClient.reportFailure(failure)
                Log.d(TAG, "Failure logged: step ${failure.stepNumber}, layer ${failure.layerReached}")
            } catch (e: Exception) {
                // Logging failure must never crash the app or block guidance.
                Log.w(TAG, "Failed to log detection failure: ${e.message}")
            }
        }
    }
}
