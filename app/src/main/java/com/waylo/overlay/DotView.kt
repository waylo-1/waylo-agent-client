package com.waylo.overlay

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.util.TypedValue
import android.view.View
import android.view.animation.LinearInterpolator

/**
 * An animated, pulsing red dot drawn on top of other apps to show the user
 * exactly where to tap.
 *
 *  - Inner dot: 80dp solid red, pulses 1.0x -> 1.3x over 800ms.
 *  - Outer ring: 100dp semi-transparent red (#44FF0000) "sonar" ripple over
 *    1200ms, offset from the inner pulse for a layered effect.
 *  - Label: a rounded rect below the dot showing the current instruction.
 *    It is hidden while the dot is moving and fades in on arrival.
 */
class DotView(context: Context) : View(context) {

    private val innerDiameterPx: Float = dp(80f)
    private val innerRadiusPx: Float = innerDiameterPx / 2f
    private val outerDiameterPx: Float = dp(100f)
    private val outerRadiusPx: Float = outerDiameterPx / 2f

    // Layout regions.
    private val padding: Float = dp(20f)            // room for outer ripple expansion
    private val labelGap: Float = dp(10f)           // gap between dot and label
    private val labelAreaPx: Float = dp(48f)        // vertical room for the label below

    private var instruction: String = "Tap here"
    private var isMoving: Boolean = false

    // Animated state.
    private var innerScale: Float = 1f
    private var ripple: Float = 0f                  // 0..1 sonar progress
    private var labelAlpha: Float = 1f              // 0..1 fade for the label

    private val innerPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.parseColor("#FF0000")
        style = Paint.Style.FILL
    }

    private val outerPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.parseColor("#44FF0000")
        style = Paint.Style.FILL
    }

    private val labelBgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.parseColor("#99000000") // 60% black
        style = Paint.Style.FILL
    }

    private val labelTextPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        textSize = dp(12f)
        textAlign = Paint.Align.CENTER
    }

    private var innerAnimator: ValueAnimator? = null
    private var rippleAnimator: ValueAnimator? = null
    private var labelAnimator: ValueAnimator? = null

    init {
        startPulse()
    }

    /** Update the instruction label text shown below the dot. */
    fun setInstruction(text: String) {
        instruction = text
        invalidate()
    }

    /** Called by OverlayManager when an animated move begins. */
    fun onMoveStart() {
        isMoving = true
        pausePulse()
        hideLabel()
    }

    /** Called by OverlayManager when the dot arrives at its destination. */
    fun onMoveEnd() {
        isMoving = false
        startPulse()
        fadeInLabel()
    }

    private fun startPulse() {
        if (innerAnimator?.isRunning == true) return

        innerAnimator = ValueAnimator.ofFloat(1f, 1.3f).apply {
            duration = 800
            repeatCount = ValueAnimator.INFINITE
            repeatMode = ValueAnimator.REVERSE
            addUpdateListener {
                innerScale = it.animatedValue as Float
                invalidate()
            }
            start()
        }

        rippleAnimator = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 1200
            repeatCount = ValueAnimator.INFINITE
            repeatMode = ValueAnimator.RESTART
            interpolator = LinearInterpolator()
            addUpdateListener {
                ripple = it.animatedValue as Float
                invalidate()
            }
            start()
        }
    }

    private fun pausePulse() {
        innerAnimator?.cancel()
        innerAnimator = null
        rippleAnimator?.cancel()
        rippleAnimator = null
        innerScale = 1f
        ripple = 0f
        invalidate()
    }

    private fun hideLabel() {
        labelAnimator?.cancel()
        labelAlpha = 0f
        invalidate()
    }

    private fun fadeInLabel() {
        labelAnimator?.cancel()
        labelAnimator = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 250
            addUpdateListener {
                labelAlpha = it.animatedValue as Float
                invalidate()
            }
            start()
        }
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val width = (outerDiameterPx + padding * 2).toInt()
        val height = (outerDiameterPx + padding * 2 + labelGap + labelAreaPx).toInt()
        setMeasuredDimension(width, height)
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)

        val centerX = width / 2f
        val dotCenterY = padding + outerRadiusPx

        // Outer sonar ring: expands from inner radius outward and fades as it grows.
        if (!isMoving) {
            val rippleRadius = innerRadiusPx + (outerRadiusPx - innerRadiusPx + dp(14f)) * ripple
            val rippleAlpha = (1f - ripple).coerceIn(0f, 1f)
            outerPaint.alpha = (0x44 * rippleAlpha).toInt()
            canvas.drawCircle(centerX, dotCenterY, rippleRadius, outerPaint)
        }

        // Inner dot (scaled by the pulse).
        canvas.drawCircle(centerX, dotCenterY, innerRadiusPx * innerScale, innerPaint)

        // Label below the dot — only when stationary and faded in.
        if (instruction.isNotBlank() && labelAlpha > 0f && !isMoving) {
            drawLabel(canvas, centerX, dotCenterY)
        }
    }

    private fun drawLabel(canvas: Canvas, centerX: Float, dotCenterY: Float) {
        val maxTextWidth = width - dp(8f)
        val lines = wrapText(instruction, maxTextWidth, maxLines = 2)

        val padH = dp(10f)
        val padV = dp(6f)
        val lineHeight = labelTextPaint.textSize * 1.3f
        val textBlockHeight = lineHeight * lines.size

        val widest = lines.maxOf { labelTextPaint.measureText(it) }
        val boxLeft = centerX - widest / 2f - padH
        val boxRight = centerX + widest / 2f + padH
        val boxTop = dotCenterY + outerRadiusPx + labelGap
        val boxBottom = boxTop + textBlockHeight + padV * 2

        val alpha = (labelAlpha * 255).toInt().coerceIn(0, 255)
        labelBgPaint.alpha = (alpha * 0.6f).toInt()
        labelTextPaint.alpha = alpha

        canvas.drawRoundRect(boxLeft, boxTop, boxRight, boxBottom, dp(8f), dp(8f), labelBgPaint)

        var baseline = boxTop + padV + labelTextPaint.textSize
        for (line in lines) {
            canvas.drawText(line, centerX, baseline, labelTextPaint)
            baseline += lineHeight
        }
    }

    /** Naive word-wrap into at most [maxLines] lines that fit [maxWidth]. */
    private fun wrapText(text: String, maxWidth: Float, maxLines: Int): List<String> {
        val words = text.split(" ")
        val lines = mutableListOf<String>()
        var current = StringBuilder()
        for (word in words) {
            val candidate = if (current.isEmpty()) word else "$current $word"
            if (labelTextPaint.measureText(candidate) <= maxWidth) {
                current = StringBuilder(candidate)
            } else {
                if (current.isNotEmpty()) lines.add(current.toString())
                current = StringBuilder(word)
                if (lines.size == maxLines - 1) break
            }
        }
        if (current.isNotEmpty() && lines.size < maxLines) lines.add(current.toString())
        if (lines.isEmpty()) lines.add(text)
        return lines
    }

    override fun onDetachedFromWindow() {
        super.onDetachedFromWindow()
        innerAnimator?.cancel()
        rippleAnimator?.cancel()
        labelAnimator?.cancel()
        innerAnimator = null
        rippleAnimator = null
        labelAnimator = null
    }

    private fun dp(value: Float): Float =
        TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP,
            value,
            resources.displayMetrics
        )
}
