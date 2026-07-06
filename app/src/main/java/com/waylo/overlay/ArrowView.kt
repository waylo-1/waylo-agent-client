package com.waylo.overlay

import android.animation.ObjectAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.view.View
import android.view.animation.AccelerateDecelerateInterpolator

/**
 * A pulsing red arrow shown at a screen edge while a step's target hasn't
 * been found yet but the instruction (or fallbackHint) implies the user needs
 * to scroll/swipe to reveal it — e.g. "swipe up to see more apps". Replaced
 * by [DotView] the moment the target actually resolves (see
 * `GuidanceEngine.onTargetLocated`).
 *
 * Same translucent/pulsing visual language as [DotView] so it reads as part
 * of the same guidance system, not a different UI element.
 */
class ArrowView(context: Context, direction: Direction) : View(context) {

    enum class Direction { UP, DOWN }

    val direction: Direction = direction

    private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(180, 217, 83, 31) // warm coral, matches DotView
        style = Paint.Style.FILL
    }

    private val haloPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(70, 217, 83, 31)
        style = Paint.Style.FILL
    }

    private val dp = resources.displayMetrics.density
    private val arrowWidth = 28 * dp
    private val arrowHeight = 34 * dp
    private val haloPadding = 14 * dp
    private val totalWidth = (arrowWidth + haloPadding * 2).toInt()
    private val totalHeight = (arrowHeight + haloPadding * 2).toInt()

    private var pulseScale = 1f

    init {
        ObjectAnimator.ofFloat(this, "pulseScale", 1f, 1.2f).apply {
            duration = 700
            repeatMode = ObjectAnimator.REVERSE
            repeatCount = ObjectAnimator.INFINITE
            interpolator = AccelerateDecelerateInterpolator()
            start()
        }
        setLayerType(LAYER_TYPE_SOFTWARE, null)
    }

    fun setPulseScale(s: Float) { pulseScale = s; invalidate() }
    fun getPulseScale() = pulseScale

    /** X offset (px) from the view's left edge to the arrow's visual centre. */
    fun centerOffsetX(): Int = totalWidth / 2

    /** Y offset (px) from the view's top edge to the arrow's visual centre. */
    fun centerOffsetY(): Int = totalHeight / 2

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        setMeasuredDimension(totalWidth, totalHeight)
    }

    override fun onDraw(canvas: Canvas) {
        val cx = width / 2f
        val cy = height / 2f
        val scale = pulseScale

        canvas.drawCircle(cx, cy, (arrowHeight / 2f + haloPadding / 2f) * scale, haloPaint)

        val halfW = (arrowWidth / 2f) * scale
        val halfH = (arrowHeight / 2f) * scale
        val path = Path()
        if (direction == Direction.UP) {
            path.moveTo(cx, cy - halfH)       // tip
            path.lineTo(cx - halfW, cy + halfH)
            path.lineTo(cx + halfW, cy + halfH)
        } else {
            path.moveTo(cx, cy + halfH)       // tip
            path.lineTo(cx - halfW, cy - halfH)
            path.lineTo(cx + halfW, cy - halfH)
        }
        path.close()
        canvas.drawPath(path, fillPaint)
    }
}
