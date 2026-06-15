package com.waylo.guidance

/**
 * A structured record of a detection miss: every on-device layer (L0/L1/L2)
 * failed to locate the target element for a step, so we are about to spend a
 * vision (Nova Pro) call.
 *
 * These records are sent to the backend (`/failure`) and stored in Supabase.
 * They become labelled training material for the future on-device YOLO model.
 */
data class DetectionFailure(
    val sessionId: String,          // UUID generated per guidance session
    val taskDescription: String,    // the original user task string
    val stepNumber: Int,
    val findDescription: String,
    val elementType: String,
    val screenRegion: String,
    val visualDescription: String,
    val targetPackage: String,
    val layerReached: Int,          // which layer failed last: 0, 1, or 2
    val screenshotBase64: String,   // the screenshot at time of failure
    val screenWidth: Int,
    val screenHeight: Int,
    val timestamp: Long = System.currentTimeMillis()
)
