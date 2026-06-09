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
 * A large, deliberately impossible-to-miss pulsing red dot drawn on top of
 * other apps. Inner solid dot (100dp), outer translucent pulsing ring (140dp),
 * and an instruction label below it.
 */
class DotView(context: Context) : View(context) {

    var onTap: (() -> Unit)? = null

    private var instructionText: String = "Tap here"

    private val innerPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.RED
        style = Paint.Style.FILL
    }

    private val outerPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(100, 255, 0, 0)
        style = Paint.Style.FILL
    }

    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        textSize = 36f
        textAlign = Paint.Align.CENTER
        setShadowLayer(4f, 0f, 2f, Color.BLACK)
    }

    private val dotSizePx = (100 * resources.displayMetrics.density).toInt()   // 100dp
    private val outerSizePx = (140 * resources.displayMetrics.density).toInt()  // 140dp

    private var pulseScale = 1f

    init {
        // Start the pulse animation immediately.
        ObjectAnimator.ofFloat(this, "pulseScale", 1f, 1.4f).apply {
            duration = 700
            repeatMode = ObjectAnimator.REVERSE
            repeatCount = ObjectAnimator.INFINITE
            interpolator = AccelerateDecelerateInterpolator()
            start()
        }
        // Software layer so the shadow layer on text renders reliably.
        setLayerType(LAYER_TYPE_SOFTWARE, null)
    }

    // Driven by the ObjectAnimator above.
    fun setPulseScale(scale: Float) {
        pulseScale = scale
        invalidate()
    }

    fun getPulseScale(): Float = pulseScale

    fun setInstruction(text: String) {
        instructionText = text
        invalidate()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val size = outerSizePx + 80 // extra space for the pulsing ring
        setMeasuredDimension(size, size + 60) // extra height for the label
    }

    override fun onDraw(canvas: Canvas) {
        val cx = width / 2f
        val cy = (outerSizePx / 2f) + 10

        // Outer pulsing ring.
        canvas.drawCircle(cx, cy, (outerSizePx / 2f) * pulseScale, outerPaint)

        // Inner solid dot.
        canvas.drawCircle(cx, cy, dotSizePx / 2f, innerPaint)

        // Instruction label below the dot.
        canvas.drawText(instructionText, cx, cy + outerSizePx / 2f + 40, textPaint)
    }

    @Suppress("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (event.action == MotionEvent.ACTION_UP) {
            onTap?.invoke()
            performClick()
            return true
        }
        return true // consume all touch events
    }

    override fun performClick(): Boolean {
        super.performClick()
        return true
    }
}
