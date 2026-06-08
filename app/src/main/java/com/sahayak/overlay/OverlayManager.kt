package com.sahayak.overlay

import android.content.Context
import android.graphics.PixelFormat
import android.os.Build
import android.util.Log
import android.view.Gravity
import android.view.WindowManager

/**
 * Draws and positions the [DotView] on top of every other app using a system
 * overlay window. Requires the SYSTEM_ALERT_WINDOW permission to be granted.
 *
 * Singleton — call [init] once (with an application context) before use.
 */
object OverlayManager {

    private const val TAG = "Sahayak"

    private var windowManager: WindowManager? = null
    private var appContext: Context? = null
    private var dotView: DotView? = null
    private var layoutParams: WindowManager.LayoutParams? = null

    /** Initialise with a context; safe to call multiple times. */
    fun init(context: Context) {
        appContext = context.applicationContext
        windowManager = appContext!!.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        Log.d(TAG, "OverlayManager initialised.")
    }

    /**
     * Show the pulsing dot at absolute screen coordinates (x, y), with [instruction]
     * shown in the label above it. If a dot is already showing it is moved instead.
     */
    fun showDot(x: Int, y: Int, instruction: String) {
        val wm = windowManager ?: run {
            Log.w(TAG, "showDot called before init().")
            return
        }

        if (dotView != null) {
            // Already showing — just update text and reposition.
            dotView?.setInstruction(instruction)
            moveDot(x, y)
            return
        }

        val view = DotView(appContext!!).apply { setInstruction(instruction) }
        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            overlayType(),
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            this.x = x
            this.y = y
        }

        try {
            wm.addView(view, params)
            dotView = view
            layoutParams = params
            Log.d(TAG, "Dot shown at ($x, $y): '$instruction'")
        } catch (e: WindowManager.BadTokenException) {
            Log.e(TAG, "Failed to add overlay (bad token). Is overlay permission granted?", e)
            dotView = null
            layoutParams = null
        } catch (e: Exception) {
            Log.e(TAG, "Failed to add overlay.", e)
            dotView = null
            layoutParams = null
        }
    }

    /** Move an already-visible dot to new screen coordinates. */
    fun moveDot(x: Int, y: Int) {
        val wm = windowManager ?: return
        val view = dotView ?: return
        val params = layoutParams ?: return
        params.x = x
        params.y = y
        try {
            wm.updateViewLayout(view, params)
            Log.d(TAG, "Dot moved to ($x, $y)")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to move overlay.", e)
        }
    }

    /** Remove the dot from the window if it is currently showing. */
    fun hideDot() {
        val wm = windowManager ?: return
        val view = dotView ?: return
        try {
            wm.removeView(view)
            Log.d(TAG, "Dot hidden.")
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "Dot was not attached.", e)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to remove overlay.", e)
        } finally {
            dotView = null
            layoutParams = null
        }
    }

    private fun overlayType(): Int {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }
    }
}
