package com.waylo.screenshot

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.Image
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Handler
import android.os.Looper
import android.util.DisplayMetrics
import android.util.Log
import android.view.WindowManager

/**
 * Manages the MediaProjection screen-capture permission and captures single
 * frames on demand for the OCR fallback layer.
 *
 * Privacy: a captured bitmap is handed to the caller's callback and then this
 * manager releases the VirtualDisplay and ImageReader immediately. It never
 * stores or caches the bitmap.
 */
object ScreenCaptureManager {

    private const val TAG = "Waylo"
    const val REQUEST_CODE = 1001

    private var projectionManager: MediaProjectionManager? = null
    private var mediaProjection: MediaProjection? = null

    // Cached the granting token's resultCode + data so the projection can be
    // (re)created. On Android 14+ a token may only be consumed ONCE, so we
    // create the MediaProjection a single time and reuse it across captures.
    private var resultCode: Int = Activity.RESULT_CANCELED
    private var resultData: Intent? = null

    /** True once we've created a live projection from the granted token. */
    private var projectionStarted = false

    private val mainHandler = Handler(Looper.getMainLooper())

    /** Fire the system screen-capture consent dialog. */
    fun requestPermission(activity: Activity) {
        val manager = ensureManager(activity)
        activity.startActivityForResult(manager.createScreenCaptureIntent(), REQUEST_CODE)
    }

    /** Store the granted token from onActivityResult. */
    fun onPermissionResult(resultCode: Int, data: Intent) {
        this.resultCode = resultCode
        this.resultData = data
        // Force the next capture to build a fresh projection from this token.
        projectionStarted = false
        mediaProjection = null
        Log.d(TAG, "Screen capture permission stored (resultCode=$resultCode).")
    }

    /** True if a usable projection token has been granted. */
    fun hasPermission(): Boolean =
        resultCode == Activity.RESULT_OK && resultData != null

    /** Forget the token (e.g. after the projection was revoked). */
    fun clearPermission() {
        resultCode = Activity.RESULT_CANCELED
        resultData = null
        projectionStarted = false
        try {
            mediaProjection?.stop()
        } catch (e: Exception) {
            Log.w(TAG, "Error stopping projection on clear.", e)
        }
        mediaProjection = null
        Log.d(TAG, "Screen capture permission cleared.")
    }

    /**
     * Get the live MediaProjection, creating it once from the stored token.
     *
     * On Android 14+ the permission token is single-use, so we must NOT call
     * getMediaProjection repeatedly — we build it once and keep it alive for the
     * whole guidance session. Returns null if no token or creation fails.
     */
    private fun getOrCreateProjection(context: Context): MediaProjection? {
        mediaProjection?.let { return it }
        if (!hasPermission()) return null

        return try {
            val manager = ensureManager(context)
            // Android 14+: the FGS must declare the mediaProjection type before
            // the projection is created. Do this synchronously on the main thread.
            com.waylo.service.WayloGuidanceService.instance?.enableMediaProjectionType()

            val projection = manager.getMediaProjection(resultCode, resultData!!)
            if (projection == null) {
                Log.e(TAG, "MediaProjection was null — token likely already used or revoked.")
                clearPermission()
                return null
            }

            // IMPORTANT (API 34+): register the callback BEFORE the projection is
            // used to create a virtual display, or the system throws.
            projection.registerCallback(object : MediaProjection.Callback() {
                override fun onStop() {
                    Log.d(TAG, "MediaProjection stopped by system.")
                    mediaProjection = null
                    projectionStarted = false
                }
            }, mainHandler)

            mediaProjection = projection
            projectionStarted = true
            Log.d(TAG, "MediaProjection created and cached for reuse.")
            projection
        } catch (e: Throwable) {
            // Catch Throwable so an Android 14 SecurityException/IllegalState
            // during elevation or projection creation can never kill the process.
            Log.e(TAG, "getOrCreateProjection failed; recovering without crashing.", e)
            clearPermission()
            null
        }
    }

    /**
     * Capture a single frame of the screen. The bitmap (or null on failure) is
     * delivered to [callback] on the main thread. Only the VirtualDisplay and
     * ImageReader are released after each frame — the MediaProjection is kept
     * alive and reused for subsequent captures (Android 14 token is single-use).
     */
    fun captureScreen(context: Context, callback: (Bitmap?) -> Unit) {
        // Always run the MediaProjection work on the main thread. On Android 14
        // elevating the FGS type and creating the projection off the main thread
        // can throw and crash the whole process.
        if (Looper.myLooper() == Looper.getMainLooper()) {
            captureScreenInternal(context, callback)
        } else {
            mainHandler.post { captureScreenInternal(context, callback) }
        }
    }

    private fun captureScreenInternal(context: Context, callback: (Bitmap?) -> Unit) {
        if (!hasPermission()) {
            Log.w(TAG, "captureScreen called without permission.")
            callback(null)
            return
        }

        val metrics = screenMetrics(context)
        val width = metrics.widthPixels
        val height = metrics.heightPixels
        val dpi = metrics.densityDpi

        try {
            val projection = getOrCreateProjection(context)
            if (projection == null) {
                callback(null)
                return
            }

            val imageReader = ImageReader.newInstance(
                width, height, PixelFormat.RGBA_8888, 2
            )

            var virtualDisplay: VirtualDisplay? = null
            var delivered = false

            // Release ONLY the per-capture resources. Keep the projection alive.
            fun cleanup() {
                try {
                    virtualDisplay?.release()
                } catch (e: Throwable) {
                    Log.w(TAG, "Error releasing VirtualDisplay.", e)
                }
                try {
                    imageReader.close()
                } catch (e: Throwable) {
                    Log.w(TAG, "Error closing ImageReader.", e)
                }
            }

            virtualDisplay = projection.createVirtualDisplay(
                "WayloCapture",
                width, height, dpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                imageReader.surface,
                null,
                mainHandler
            )

            imageReader.setOnImageAvailableListener({ reader ->
                if (delivered) return@setOnImageAvailableListener
                var image: Image? = null
                try {
                    image = reader.acquireLatestImage()
                    if (image != null) {
                        val bitmap = imageToBitmap(image, width, height)
                        delivered = true
                        cleanup()
                        callback(bitmap)
                    }
                } catch (e: Throwable) {
                    Log.e(TAG, "Error reading captured image.", e)
                    if (!delivered) {
                        delivered = true
                        cleanup()
                        callback(null)
                    }
                } finally {
                    image?.close()
                }
            }, mainHandler)

            // Safety timeout: if no frame arrives, clean up and report failure.
            mainHandler.postDelayed({
                if (!delivered) {
                    Log.w(TAG, "Capture timed out with no frame.")
                    delivered = true
                    cleanup()
                    callback(null)
                }
            }, 2500)

        } catch (e: Throwable) {
            // Catch Throwable (not just Exception) so an Android 14 projection
            // error can never crash the host process — fall back to null.
            Log.e(TAG, "Capture failed; recovering without crashing.", e)
            clearPermission()
            callback(null)
        }
    }

    /** Convert a captured RGBA Image (with row padding) into a cropped Bitmap. */
    private fun imageToBitmap(image: Image, width: Int, height: Int): Bitmap {
        val plane = image.planes[0]
        val buffer = plane.buffer
        val pixelStride = plane.pixelStride
        val rowStride = plane.rowStride
        val rowPadding = rowStride - pixelStride * width

        val bitmapWidth = width + rowPadding / pixelStride
        val full = Bitmap.createBitmap(
            bitmapWidth, height, Bitmap.Config.ARGB_8888
        )
        full.copyPixelsFromBuffer(buffer)

        return if (bitmapWidth != width) {
            // Crop away the row padding.
            val cropped = Bitmap.createBitmap(full, 0, 0, width, height)
            full.recycle()
            cropped
        } else {
            full
        }
    }

    private fun ensureManager(context: Context): MediaProjectionManager {
        return projectionManager ?: (context.applicationContext
            .getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager)
            .also { projectionManager = it }
    }

    @Suppress("DEPRECATION")
    private fun screenMetrics(context: Context): DisplayMetrics {
        val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val metrics = DisplayMetrics()
        wm.defaultDisplay.getRealMetrics(metrics)
        return metrics
    }
}
