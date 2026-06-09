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
 * A small, very translucent pulsing red dot drawn on top of other apps, with a
 * translucent label pill below it. Sized small and see-through so the user can
 * still see — and tap — the real button underneath it.
 *
 * The dot's visual centre is NOT the view's top-left. [centerOffsetX] /
 * [centerOffsetY] expose where the dot centre sits inside the view so the
 * OverlayManager can place the centre exactly on the target.
 */
class DotView(context: Context) : View(context) {

    var onTap: (() -> Unit)? = null

    private var instructionText: String = "Tap here"

    // Very translucent so the underlying button stays visible/pressable.
    private val innerPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(110, 255, 40, 40)  // see-through red core
        style = Paint.Style.FILL
    }

    private val ringPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(45, 255, 40, 40)   // faint pulsing halo
        style = Paint.Style.FILL
    }

    private val textBgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(140, 0, 0, 0)      // semi-transparent black pill
        style = Paint.Style.FILL
    }

    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        textSize = 24f
        textAlign = Paint.Align.CENTER
        setShadowLayer(3f, 0f, 1f, Color.BLACK)
    }

    private val dp = resources.displayMetrics.density
    private val innerRadius = 14 * dp   // 14dp inner dot (small)
    private val outerRadius = 24 * dp   // 24dp outer ring
    private val totalSize = (outerRadius * 2 + 8 * dp).toInt()
    private val labelGap = 40 * dp      // space reserved below for the label

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

    /** X offset (px) from the view's left edge to the dot's visual centre. */
    fun centerOffsetX(): Int = totalSize / 2

    /** Y offset (px) from the view's top edge to the dot's visual centre. */
    fun centerOffsetY(): Int = (outerRadius + 4 * dp).toInt()

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        setMeasuredDimension(totalSize, totalSize + labelGap.toInt())
    }

    override fun onDraw(canvas: Canvas) {
        val cx = width / 2f
        val cy = outerRadius + 4 * dp

        // pulsing outer ring
        canvas.drawCircle(cx, cy, outerRadius * pulseScale, ringPaint)

        // solid (translucent) inner dot
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
