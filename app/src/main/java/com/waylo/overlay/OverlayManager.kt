package com.waylo.overlay

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.PixelFormat
import android.provider.Settings
import android.util.Log
import android.view.Gravity
import android.view.WindowManager
import android.view.animation.DecelerateInterpolator
import com.waylo.guidance.GuidanceEngine
import com.waylo.ocr.ScreenAnalysisPipeline.PipelineResult

/**
 * Draws and positions the [DotView] on top of every other app using a system
 * overlay window (TYPE_APPLICATION_OVERLAY).
 *
 * Ownership: initialised from [com.waylo.service.WayloGuidanceService] with the
 * service context. We store the *application* context so the WindowManager
 * reference never becomes invalid when an Activity is destroyed. Never call
 * [init] from an Activity.
 */
object OverlayManager {

    private const val TAG = "WAYLO_DOT"

    private var windowManager: WindowManager? = null
    private var dotView: DotView? = null
    private var context: Context? = null

    @Volatile
    var isAttached = false
        private set

    fun init(ctx: Context) {
        context = ctx.applicationContext // ALWAYS use applicationContext
        windowManager = ctx.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        Log.e(TAG, "OverlayManager.init: wm=$windowManager ctx=${ctx.javaClass.simpleName}")
    }

    fun showDot(x: Int, y: Int, instruction: String = "Tap here") {
        Log.e(TAG, "showDot called at x=$x y=$y")
        val ctx = context ?: run {
            Log.e(TAG, "showDot: context is null, cannot show dot")
            return
        }
        val wm = windowManager ?: run {
            Log.e(TAG, "showDot: windowManager is null, cannot show dot")
            return
        }
        Log.e(TAG, "canDrawOverlays: ${Settings.canDrawOverlays(ctx)}")
        if (!Settings.canDrawOverlays(ctx)) {
            Log.e(TAG, "showDot: SYSTEM_ALERT_WINDOW not granted!")
            return
        }

        // Remove any existing dot first.
        hideDot()

        val dot = DotView(ctx)
        dot.setInstruction(instruction)
        dot.onTap = { GuidanceEngine.onUserTappedTarget() }

        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            this.x = x
            this.y = y
        }

        try {
            wm.addView(dot, params)
            dotView = dot
            isAttached = true
            Log.e(TAG, "addView SUCCESS / showDot SUCCESS at $x,$y")
        } catch (e: Exception) {
            Log.e(TAG, "addView FAILED: ${e.javaClass.simpleName}: ${e.message}", e)
        }
    }

    fun hideDot() {
        val dot = dotView ?: return
        val wm = windowManager ?: return
        try {
            wm.removeView(dot)
            Log.e(TAG, "hideDot: removed successfully")
        } catch (e: Exception) {
            Log.e(TAG, "hideDot exception: ${e.message}")
        } finally {
            dotView = null
            isAttached = false
        }
    }

    fun moveDotAnimated(toX: Int, toY: Int, duration: Long = 400) {
        val dot = dotView ?: run { showDot(toX, toY); return }
        val wm = windowManager ?: return
        val params = dot.layoutParams as? WindowManager.LayoutParams ?: return
        val startX = params.x
        val startY = params.y

        ValueAnimator.ofFloat(0f, 1f).apply {
            this.duration = duration
            interpolator = DecelerateInterpolator()
            addUpdateListener { anim ->
                val fraction = anim.animatedFraction
                params.x = (startX + (toX - startX) * fraction).toInt()
                params.y = (startY + (toY - startY) * fraction).toInt()
                try {
                    wm.updateViewLayout(dot, params)
                } catch (e: Exception) {
                    cancel()
                }
            }
            start()
        }
    }

    fun showDotAtResult(result: PipelineResult) {
        if (isAttached) {
            dotView?.setInstruction(result.label)
            moveDotAnimated(result.x, result.y)
        } else {
            showDot(result.x, result.y, result.label)
        }
    }

    fun destroy() {
        hideDot()
        windowManager = null
        context = null
        Log.e(TAG, "OverlayManager destroyed.")
    }
}
