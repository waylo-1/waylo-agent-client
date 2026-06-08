package com.waylo.overlay

import android.animation.ObjectAnimator
import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.util.TypedValue
import android.view.View

/**
 * An animated, pulsing red dot drawn on top of other apps to show the user exactly
 * where to tap. A small white instruction label is rendered just above the dot.
 *
 * The view sizes itself to fit both the 80dp dot (with room for the pulse scale) and
 * the label text above it.
 */
class DotView(context: Context) : View(context) {

    private val dotDiameterPx: Float = dp(80f)
    private val dotRadiusPx: Float = dotDiameterPx / 2f

    // Extra vertical room above the dot for the instruction label.
    private val labelAreaPx: Float = dp(40f)
    // Padding so the 1.3x pulse scale never clips at the edges.
    private val pulsePaddingPx: Float = dp(16f)

    private var instruction: String = "Tap here"

    private val dotPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.parseColor("#FF0000")
        style = Paint.Style.FILL
    }

    private val labelBgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.parseColor("#CC000000")
        style = Paint.Style.FILL
    }

    private val labelTextPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        textSize = dp(16f)
        textAlign = Paint.Align.CENTER
    }

    private var pulseAnimatorX: ObjectAnimator? = null
    private var pulseAnimatorY: ObjectAnimator? = null

    init {
        // Pivot around the dot center so the pulse scales symmetrically.
        startPulse()
    }

    /** Update the instruction label text shown above the dot. */
    fun setInstruction(text: String) {
        instruction = text
        invalidate()
    }

    private fun startPulse() {
        pulseAnimatorX = ObjectAnimator.ofFloat(this, View.SCALE_X, 1f, 1.3f).apply {
            duration = 800
            repeatCount = ValueAnimator.INFINITE
            repeatMode = ValueAnimator.REVERSE
            start()
        }
        pulseAnimatorY = ObjectAnimator.ofFloat(this, View.SCALE_Y, 1f, 1.3f).apply {
            duration = 800
            repeatCount = ValueAnimator.INFINITE
            repeatMode = ValueAnimator.REVERSE
            start()
        }
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val width = (dotDiameterPx + pulsePaddingPx * 2).toInt()
        val height = (dotDiameterPx + pulsePaddingPx * 2 + labelAreaPx).toInt()
        setMeasuredDimension(width, height)
        // Pivot at the dot center (which sits below the label area).
        pivotX = width / 2f
        pivotY = labelAreaPx + pulsePaddingPx + dotRadiusPx
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)

        val centerX = width / 2f
        val dotCenterY = labelAreaPx + pulsePaddingPx + dotRadiusPx

        // Draw the red dot.
        canvas.drawCircle(centerX, dotCenterY, dotRadiusPx, dotPaint)

        // Draw the instruction label above the dot, if present.
        if (instruction.isNotBlank()) {
            val textWidth = labelTextPaint.measureText(instruction)
            val padH = dp(12f)
            val padV = dp(6f)
            val boxLeft = centerX - textWidth / 2f - padH
            val boxRight = centerX + textWidth / 2f + padH
            val boxBottom = labelAreaPx - dp(4f)
            val boxTop = boxBottom - (labelTextPaint.textSize + padV * 2)

            canvas.drawRoundRect(
                boxLeft, boxTop, boxRight, boxBottom,
                dp(8f), dp(8f), labelBgPaint
            )
            val textBaseline = boxBottom - padV - labelTextPaint.descent()
            canvas.drawText(instruction, centerX, textBaseline, labelTextPaint)
        }
    }

    override fun onDetachedFromWindow() {
        super.onDetachedFromWindow()
        pulseAnimatorX?.cancel()
        pulseAnimatorY?.cancel()
        pulseAnimatorX = null
        pulseAnimatorY = null
    }

    private fun dp(value: Float): Float =
        TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP,
            value,
            resources.displayMetrics
        )
}
