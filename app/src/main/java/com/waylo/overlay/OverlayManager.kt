package com.waylo.overlay

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.PixelFormat
import android.os.Build
import android.util.Log
import android.view.Gravity
import android.view.WindowManager
import android.view.animation.DecelerateInterpolator
import com.waylo.ocr.ScreenAnalysisPipeline.PipelineResult

/**
 * Draws and positions the [DotView] on top of every other app using a system
 * overlay window. Requires the SYSTEM_ALERT_WINDOW permission to be granted.
 *
 * Singleton — call [init] once (with an application context) before use.
 */
object OverlayManager {

    private const val TAG = "Waylo"

    private var windowManager: WindowManager? = null
    private var appContext: Context? = null
    private var dotView: DotView? = null
    private var layoutParams: WindowManager.LayoutParams? = null
    private var moveAnimator: ValueAnimator? = null

    /** Initialise with a context; safe to call multiple times. */
    fun init(context: Context) {
        appContext = context.applicationContext
        windowManager = appContext!!.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        Log.d(TAG, "OverlayManager initialised.")
    }

    /** True if the dot is currently attached to the window. */
    fun isShowing(): Boolean = dotView != null

    /**
     * Show the pulsing dot at absolute screen coordinates (x, y), with [instruction]
     * shown in the label. If a dot is already showing it animates to the new spot.
     */
    fun showDot(x: Int, y: Int, instruction: String) {
        val wm = windowManager ?: run {
            Log.w(TAG, "showDot called before init().")
            return
        }

        if (dotView != null) {
            dotView?.setInstruction(instruction)
            moveDotAnimated(x, y)
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

    /**
     * Show or move the dot based on a pipeline result. Animates if already
     * visible, otherwise shows it in place.
     */
    fun showDotAtResult(result: PipelineResult) {
        if (result.source == "failed") {
            Log.d(TAG, "showDotAtResult: pipeline failed, not moving dot.")
            return
        }
        if (dotView == null) {
            showDot(result.x, result.y, result.label)
        } else {
            dotView?.setInstruction(result.label)
            moveDotAnimated(result.x, result.y)
        }
    }

    /** Instantly reposition the dot (no animation). */
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

    /**
     * Smoothly slide the dot from its current position to (toX, toY).
     * The pulse/label is paused during the move and resumed on arrival, so the
     * dot never teleports.
     */
    fun moveDotAnimated(toX: Int, toY: Int, duration: Long = 400) {
        val wm = windowManager ?: return
        val view = dotView ?: return
        val params = layoutParams ?: return

        moveAnimator?.cancel()

        val fromX = params.x
        val fromY = params.y
        if (fromX == toX && fromY == toY) return

        view.onMoveStart()

        moveAnimator = ValueAnimator.ofFloat(0f, 1f).apply {
            this.duration = duration
            interpolator = DecelerateInterpolator()
            addUpdateListener { animator ->
                val t = animator.animatedValue as Float
                params.x = (fromX + (toX - fromX) * t).toInt()
                params.y = (fromY + (toY - fromY) * t).toInt()
                try {
                    wm.updateViewLayout(view, params)
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to update overlay during animation.", e)
                    cancel()
                }
            }
            // Resume the pulse + label fade-in once the dot arrives.
            addOnArrival { view.onMoveEnd() }
            start()
        }
    }

    /** Remove the dot from the window if it is currently showing. */
    fun hideDot() {
        moveAnimator?.cancel()
        moveAnimator = null
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

    /** Small helper to run [block] when a ValueAnimator finishes (not cancelled). */
    private fun ValueAnimator.addOnArrival(block: () -> Unit) {
        addListener(object : android.animation.AnimatorListenerAdapter() {
            private var cancelled = false
            override fun onAnimationCancel(animation: android.animation.Animator) {
                cancelled = true
            }
            override fun onAnimationEnd(animation: android.animation.Animator) {
                if (!cancelled) block()
            }
        })
    }
}
