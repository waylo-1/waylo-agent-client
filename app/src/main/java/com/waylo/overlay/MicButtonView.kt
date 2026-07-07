package com.waylo.overlay

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.view.MotionEvent
import android.view.View

/**
 * Small persistent overlay button — the fallback path into the correction
 * flow (see `com.waylo.correction.CorrectionFlow`) for devices/situations
 * where the volume-down double-press can't be captured. Unlike [DotView]/
 * [ArrowView], this one IS touchable (it's the whole point of the button).
 */
class MicButtonView(context: Context) : View(context) {

    var onTap: (() -> Unit)? = null

    private val dp = resources.displayMetrics.density
    private val radius = 20 * dp
    private val totalSize = (radius * 2 + 8 * dp).toInt()

    private val circlePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(200, 13, 27, 42) // navy, matches DotView's label pill
        style = Paint.Style.FILL
    }

    private val micPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.rgb(245, 245, 240) // soft off-white, matches DotView's text
        style = Paint.Style.FILL
    }

    init {
        setLayerType(LAYER_TYPE_SOFTWARE, null)
    }

    fun centerOffsetX(): Int = totalSize / 2
    fun centerOffsetY(): Int = totalSize / 2

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        setMeasuredDimension(totalSize, totalSize)
    }

    override fun onDraw(canvas: Canvas) {
        val cx = width / 2f
        val cy = height / 2f
        canvas.drawCircle(cx, cy, radius, circlePaint)

        // Minimal mic glyph: a capsule + a small stand, good enough at this size.
        val capsuleWidth = radius * 0.5f
        val capsuleHeight = radius * 0.9f
        canvas.drawRoundRect(
            cx - capsuleWidth / 2, cy - capsuleHeight / 2,
            cx + capsuleWidth / 2, cy + capsuleHeight / 4,
            capsuleWidth / 2, capsuleWidth / 2, micPaint
        )
        canvas.drawRect(cx - 2 * dp, cy + capsuleHeight / 4, cx + 2 * dp, cy + capsuleHeight / 2 + 4 * dp, micPaint)
    }

    @Suppress("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (event.action == MotionEvent.ACTION_UP) {
            onTap?.invoke()
            performClick()
        }
        return true
    }

    override fun performClick(): Boolean {
        super.performClick()
        return true
    }
}
