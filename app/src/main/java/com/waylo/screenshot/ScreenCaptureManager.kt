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

    // Cached the granting token's resultCode + data so projection can be
    // recreated each capture (a projection can be stopped by the system).
    private var resultCode: Int = Activity.RESULT_CANCELED
    private var resultData: Intent? = null

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
        Log.d(TAG, "Screen capture permission stored (resultCode=$resultCode).")
    }

    /** True if a usable projection token has been granted. */
    fun hasPermission(): Boolean =
        resultCode == Activity.RESULT_OK && resultData != null

    /** Forget the token (e.g. after the projection was revoked). */
    fun clearPermission() {
        resultCode = Activity.RESULT_CANCELED
        resultData = null
        try {
            mediaProjection?.stop()
        } catch (e: Exception) {
            Log.w(TAG, "Error stopping projection on clear.", e)
        }
        mediaProjection = null
        Log.d(TAG, "Screen capture permission cleared.")
    }

    /**
     * Capture a single frame of the screen. The bitmap (or null on failure) is
     * delivered to [callback] on the main thread. The VirtualDisplay and
     * ImageReader are released immediately after the frame is read.
     */
    fun captureScreen(context: Context, callback: (Bitmap?) -> Unit) {
        if (!hasPermission()) {
            Log.w(TAG, "captureScreen called without permission.")
            mainHandler.post { callback(null) }
            return
        }

        val metrics = screenMetrics(context)
        val width = metrics.widthPixels
        val height = metrics.heightPixels
        val dpi = metrics.densityDpi

        try {
            val manager = ensureManager(context)
            // Android 14+: the foreground service must declare the
            // mediaProjection type before a projection is started.
            com.waylo.service.WayloGuidanceService.instance?.enableMediaProjectionType()

            // Recreate the projection from the stored token for each capture.
            val projection = manager.getMediaProjection(resultCode, resultData!!).also {
                mediaProjection = it
            }

            if (projection == null) {
                Log.e(TAG, "MediaProjection was null — token likely revoked.")
                clearPermission()
                mainHandler.post { callback(null) }
                return
            }

            val imageReader = ImageReader.newInstance(
                width, height, PixelFormat.RGBA_8888, 2
            )

            // A projection requires a registered callback on API 34+.
            projection.registerCallback(object : MediaProjection.Callback() {
                override fun onStop() {
                    Log.d(TAG, "MediaProjection stopped.")
                }
            }, mainHandler)

            var virtualDisplay: VirtualDisplay? = null
            var delivered = false

            fun cleanup() {
                try {
                    virtualDisplay?.release()
                } catch (e: Exception) {
                    Log.w(TAG, "Error releasing VirtualDisplay.", e)
                }
                try {
                    imageReader.close()
                } catch (e: Exception) {
                    Log.w(TAG, "Error closing ImageReader.", e)
                }
                try {
                    projection.stop()
                } catch (e: Exception) {
                    Log.w(TAG, "Error stopping projection.", e)
                }
                mediaProjection = null
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
                        mainHandler.post { callback(bitmap) }
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Error reading captured image.", e)
                    if (!delivered) {
                        delivered = true
                        cleanup()
                        mainHandler.post { callback(null) }
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
            }, 2000)

        } catch (e: SecurityException) {
            Log.e(TAG, "SecurityException during capture — projection revoked.", e)
            clearPermission()
            mainHandler.post { callback(null) }
        } catch (e: Exception) {
            Log.e(TAG, "Unexpected error during capture.", e)
            mainHandler.post { callback(null) }
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
