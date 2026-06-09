package com.waylo.overlay

import android.animation.ObjectAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.view.MotionEvent
import android.view.View
import android.view.animation.AccelerateDecelerateInterpolator

/**
 * A small, translucent pulsing red dot drawn on top of other apps, with a
 * semi-transparent label pill below it. Sized to point at a target without
 * obscuring it: 22dp inner dot, 36dp outer ring.
 */
class DotView(context: Context) : View(context) {

    var onTap: (() -> Unit)? = null

    private var instructionText: String = "Tap here"

    private val innerPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(200, 255, 50, 50)  // semi-transparent red
        style = Paint.Style.FILL
    }

    private val ringPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(80, 255, 50, 50)   // very translucent ring
        style = Paint.Style.FILL
    }

    private val textBgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(160, 0, 0, 0)      // semi-transparent black bg
        style = Paint.Style.FILL
    }

    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        textSize = 28f
        textAlign = Paint.Align.CENTER
        setShadowLayer(3f, 0f, 1f, Color.BLACK)
    }

    private val dp = resources.displayMetrics.density
    private val innerRadius = 22 * dp   // 22dp inner dot
    private val outerRadius = 36 * dp   // 36dp outer ring
    private val totalSize = (outerRadius * 2 + 8 * dp).toInt()

    private var pulseScale = 1f

    init {
        ObjectAnimator.ofFloat(this, "pulseScale", 1f, 1.25f).apply {
            duration = 900
            repeatMode = ObjectAnimator.REVERSE
            repeatCount = ObjectAnimator.INFINITE
            interpolator = AccelerateDecelerateInterpolator()
            start()
        }
        setLayerType(LAYER_TYPE_SOFTWARE, null)
    }

    fun setPulseScale(s: Float) { pulseScale = s; invalidate() }
    fun getPulseScale() = pulseScale
    fun setInstruction(text: String) { instructionText = text; invalidate() }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        setMeasuredDimension(totalSize, totalSize + (40 * dp).toInt())
    }

    override fun onDraw(canvas: Canvas) {
        val cx = width / 2f
        val cy = outerRadius + 4 * dp

        // pulsing outer ring
        canvas.drawCircle(cx, cy, outerRadius * pulseScale, ringPaint)

        // solid inner dot
        canvas.drawCircle(cx, cy, innerRadius, innerPaint)

        // label pill background
        val labelY = cy + outerRadius + 8 * dp
        val textWidth = textPaint.measureText(instructionText)
        val pad = 10 * dp
        canvas.drawRoundRect(
            cx - textWidth / 2 - pad, labelY - 22 * dp,
            cx + textWidth / 2 + pad, labelY + 6 * dp,
            8 * dp, 8 * dp, textBgPaint
        )
        canvas.drawText(instructionText, cx, labelY, textPaint)
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
