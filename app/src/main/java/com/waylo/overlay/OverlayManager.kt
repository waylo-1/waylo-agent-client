package com.waylo.overlay

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.PixelFormat
import android.provider.Settings
import android.util.Log
import android.view.Gravity
import android.view.WindowManager
import android.view.animation.DecelerateInterpolator
import com.waylo.ocr.ScreenAnalysisPipeline.PipelineResult

/**
 * Draws and positions the [DotView] on top of every other app using a system
 * overlay window (TYPE_APPLICATION_OVERLAY).
 *
 * Key behaviours:
 *  - The overlay window is NON-TOUCHABLE: every touch passes straight through to
 *    the app underneath, so the user can press the real button under the dot.
 *  - Positions are given as the TARGET CENTRE (x, y). We offset by the dot's
 *    internal centre so the dot sits exactly on the button, not beside it.
 *  - A single [DotView] instance is reused across steps and animated between
 *    targets, giving a seamless glide instead of a despawn/respawn.
 *
 * Ownership: initialised from [com.waylo.service.WayloGuidanceService] with the
 * service (application) context so the WindowManager reference stays valid when
 * Activities are destroyed. Never call [init] from an Activity.
 */
object OverlayManager {

    private const val TAG = "WAYLO_DOT"

    private var windowManager: WindowManager? = null
    private var dotView: DotView? = null
    private var context: Context? = null
    private var moveAnimator: ValueAnimator? = null

    @Volatile
    var isAttached = false
        private set

    private var arrowView: ArrowView? = null

    @Volatile
    var isArrowAttached = false
        private set

    fun init(ctx: Context) {
        context = ctx.applicationContext // ALWAYS use applicationContext
        windowManager = ctx.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        Log.e(TAG, "OverlayManager.init: wm=$windowManager ctx=${ctx.javaClass.simpleName}")
    }

    /**
     * Show the dot with its centre at the target ([x], [y]) in screen
     * coordinates. If a dot is already attached, the label is updated and the
     * dot glides to the new target instead of respawning.
     */
    fun showDot(x: Int, y: Int, instruction: String = "Tap here") {
        if (isAttached) {
            dotView?.setInstruction(instruction)
            moveDotAnimated(x, y)
            return
        }

        Log.e(TAG, "showDot called at centre x=$x y=$y")
        val ctx = context ?: run {
            Log.e(TAG, "showDot: context is null, cannot show dot")
            return
        }
        val wm = windowManager ?: run {
            Log.e(TAG, "showDot: windowManager is null, cannot show dot")
            return
        }
        if (!Settings.canDrawOverlays(ctx)) {
            Log.e(TAG, "showDot: SYSTEM_ALERT_WINDOW not granted!")
            return
        }

        val dot = DotView(ctx)
        dot.setInstruction(instruction)

        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            // NOT_TOUCHABLE => every touch passes through to the app below, so
            // the user can press the real button under the translucent dot.
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            // Place the dot's CENTRE on the target. Measure first so the
            // centre offsets are valid.
            dot.measure(0, 0)
            this.x = x - dot.centerOffsetX()
            this.y = y - dot.centerOffsetY()
        }

        try {
            wm.addView(dot, params)
            dotView = dot
            isAttached = true
            Log.e(TAG, "addView SUCCESS at centre $x,$y (topLeft ${params.x},${params.y})")
        } catch (e: Exception) {
            Log.e(TAG, "addView FAILED: ${e.javaClass.simpleName}: ${e.message}", e)
        }
    }

    fun hideDot() {
        moveAnimator?.cancel()
        moveAnimator = null
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

    /**
     * Glide the existing dot so its CENTRE lands on ([toX], [toY]). Falls back to
     * [showDot] if nothing is attached yet.
     */
    fun moveDotAnimated(toX: Int, toY: Int, duration: Long = 450) {
        val dot = dotView ?: run { showDot(toX, toY); return }
        val wm = windowManager ?: return
        val params = dot.layoutParams as? WindowManager.LayoutParams ?: return

        val targetX = toX - dot.centerOffsetX()
        val targetY = toY - dot.centerOffsetY()
        val startX = params.x
        val startY = params.y

        // Already there — nothing to animate.
        if (startX == targetX && startY == targetY) return

        moveAnimator?.cancel()
        moveAnimator = ValueAnimator.ofFloat(0f, 1f).apply {
            this.duration = duration
            interpolator = DecelerateInterpolator()
            addUpdateListener { anim ->
                val f = anim.animatedFraction
                params.x = (startX + (targetX - startX) * f).toInt()
                params.y = (startY + (targetY - startY) * f).toInt()
                try {
                    wm.updateViewLayout(dot, params)
                } catch (e: Exception) {
                    cancel()
                }
            }
            start()
        }
    }

    /** Position the dot on a pipeline result, using [labelOverride] if provided. */
    fun showDotAtResult(result: PipelineResult, labelOverride: String? = null) {
        val label = labelOverride ?: result.label
        showDot(result.x, result.y, label)
    }

    /**
     * Show a pulsing arrow at the horizontal centre of the screen, pinned to
     * the top edge ([ArrowView.Direction.UP]) or bottom edge
     * ([ArrowView.Direction.DOWN]) depending on [direction] — used while a
     * step's target hasn't been found yet but the instruction implies the
     * user needs to scroll/swipe to reveal it. Idempotent: calling again with
     * the same direction is a no-op; a different direction respawns the view.
     */
    fun showArrow(direction: ArrowView.Direction) {
        if (isArrowAttached && arrowView?.direction == direction) return
        hideArrow()

        val ctx = context ?: run {
            Log.e(TAG, "showArrow: context is null, cannot show arrow")
            return
        }
        val wm = windowManager ?: run {
            Log.e(TAG, "showArrow: windowManager is null, cannot show arrow")
            return
        }
        if (!Settings.canDrawOverlays(ctx)) {
            Log.e(TAG, "showArrow: SYSTEM_ALERT_WINDOW not granted!")
            return
        }

        val metrics = android.util.DisplayMetrics()
        @Suppress("DEPRECATION")
        wm.defaultDisplay.getRealMetrics(metrics)

        val arrow = ArrowView(ctx, direction)
        arrow.measure(0, 0)
        val edgeMarginPx = (48 * ctx.resources.displayMetrics.density).toInt()
        val centerX = metrics.widthPixels / 2
        val edgeY = when (direction) {
            ArrowView.Direction.UP -> edgeMarginPx
            ArrowView.Direction.DOWN -> metrics.heightPixels - edgeMarginPx
        }

        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            this.x = centerX - arrow.centerOffsetX()
            this.y = edgeY - arrow.centerOffsetY()
        }

        try {
            wm.addView(arrow, params)
            arrowView = arrow
            isArrowAttached = true
            Log.e(TAG, "showArrow: SUCCESS direction=$direction at ${params.x},${params.y}")
        } catch (e: Exception) {
            Log.e(TAG, "showArrow addView FAILED: ${e.javaClass.simpleName}: ${e.message}", e)
        }
    }

    fun hideArrow() {
        val arrow = arrowView ?: return
        val wm = windowManager ?: return
        try {
            wm.removeView(arrow)
        } catch (e: Exception) {
            Log.e(TAG, "hideArrow exception: ${e.message}")
        } finally {
            arrowView = null
            isArrowAttached = false
        }
    }

    fun destroy() {
        hideDot()
        hideArrow()
        windowManager = null
        context = null
        Log.e(TAG, "OverlayManager destroyed.")
    }
}
