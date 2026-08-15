package com.waylo.overlay

import android.animation.ObjectAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.DashPathEffect
import android.graphics.Paint
import android.graphics.RectF
import android.view.MotionEvent
import android.view.View
import android.view.animation.AccelerateDecelerateInterpolator
import kotlin.math.max

/**
 * A translucent red dotted box drawn on top of other apps, with a label pill
 * below it. Drawn see-through so the user can still see — and tap — the real
 * control underneath.
 *
 * The box is ALWAYS a dashed red rectangle (no centre dot): a box covers more
 * area than a point, so a slightly-off placement still frames the real control
 * ("more room for error"). [setBox] supplies the matched element's on-screen
 * size so the box hugs it; when that size is unknown (OCR/vision hits) the box
 * falls back to a comfortable default square around the centre.
 *
 * The box's visual centre is NOT the view's top-left. [centerOffsetX] /
 * [centerOffsetY] expose where the centre sits inside the view so the
 * OverlayManager can place it exactly on the target.
 */
class DotView(context: Context) : View(context) {

    var onTap: (() -> Unit)? = null

    private var instructionText: String = "Tap here"

    /** Target element size in px; 0 => size unknown, use [defaultBoxHalf]. */
    private var boxW: Int = 0
    private var boxH: Int = 0

    private val textBgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(170, 13, 27, 42)   // semi-transparent navy pill (#0D1B2A), not pure black
        style = Paint.Style.FILL
    }

    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.rgb(245, 245, 240)      // soft off-white (#F5F5F0), not pure white
        textSize = 24f
        textAlign = Paint.Align.CENTER
        setShadowLayer(3f, 0f, 1f, Color.argb(200, 13, 27, 42)) // navy shadow, not pure black
    }

    // Red dashed outline + faint red wash. Red all the time, as requested.
    private val boxStrokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.rgb(220, 38, 38)        // strong red (#DC2626)
        style = Paint.Style.STROKE
        strokeWidth = 5 * resources.displayMetrics.density
        pathEffect = DashPathEffect(
            floatArrayOf(13 * resources.displayMetrics.density, 9 * resources.displayMetrics.density), 0f
        )
    }
    private val boxFillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(30, 220, 38, 38)   // barely-there red wash so the element stays readable
        style = Paint.Style.FILL
    }

    private val dp = resources.displayMetrics.density
    private val boxPad = 14 * dp          // dashed rect sits this far outside the element bounds
    private val defaultBoxHalf = 42 * dp  // half-size used when the element's real size is unknown
    private val strokeMargin = 4 * dp     // keeps the dashed stroke from clipping at the view edge
    private val labelGap = 40 * dp        // space reserved below for the label

    private var pulseScale = 1f

    init {
        // The pulse now gently breathes the box outline's opacity (not its
        // size) so it draws the eye without the box jumping around.
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

    /**
     * Update the box to the matched element's on-screen size ([wPx]/[hPx]).
     * 0,0 means "size unknown" — the box falls back to a default square.
     * Requests a re-layout so the (WRAP_CONTENT) overlay window resizes to fit.
     */
    fun setBox(wPx: Int, hPx: Int) {
        val w = max(0, wPx)
        val h = max(0, hPx)
        if (w == boxW && h == boxH) return
        boxW = w
        boxH = h
        requestLayout()
        invalidate()
    }

    /** Half-size of the drawn box (element bounds or default, plus padding). */
    private fun boxHalfW(): Float = (if (boxW > 0) boxW / 2f else defaultBoxHalf) + boxPad
    private fun boxHalfH(): Float = (if (boxH > 0) boxH / 2f else defaultBoxHalf) + boxPad

    /** Half the drawn content size (px) — the box plus a margin for the stroke. */
    private fun halfContentW(): Float = boxHalfW() + strokeMargin
    private fun halfContentH(): Float = boxHalfH() + strokeMargin

    /** Full view width — wide enough for the box AND the label pill. */
    private fun contentWidth(): Float =
        max(halfContentW() * 2f, textPaint.measureText(instructionText) + 20 * dp)

    /** X offset (px) from the view's left edge to the box's visual centre. */
    fun centerOffsetX(): Int = (contentWidth() / 2f).toInt()

    /** Y offset (px) from the view's top edge to the box's visual centre. */
    fun centerOffsetY(): Int = halfContentH().toInt()

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        setMeasuredDimension(contentWidth().toInt(), (halfContentH() * 2f + labelGap).toInt())
    }

    override fun onDraw(canvas: Canvas) {
        val cx = width / 2f
        val cy = halfContentH()
        val hw = boxHalfW()
        val hh = boxHalfH()

        val rect = RectF(cx - hw, cy - hh, cx + hw, cy + hh)
        val r = 14 * dp
        // Breathe the outline opacity between ~70% and full for attention.
        boxStrokePaint.alpha = (178 + (pulseScale - 1f) / 0.25f * 77f).toInt().coerceIn(0, 255)
        canvas.drawRoundRect(rect, r, r, boxFillPaint)
        canvas.drawRoundRect(rect, r, r, boxStrokePaint)

        // label pill below the box
        val labelY = cy + hh + 24 * dp
        val textWidth = textPaint.measureText(instructionText)
        val pad = 10 * dp
        canvas.drawRoundRect(
            cx - textWidth / 2 - pad, labelY - 22 * dp,
            cx + textWidth / 2 + pad, labelY + 6 * dp,
            8 * dp, 8 * dp, textBgPaint
        )
        canvas.drawText(instructionText, cx, labelY, textPaint)
    }

    // The overlay window is non-touchable (touches pass through to the app), so
    // this is normally never called. Kept for the dev/demo tappable path.
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
