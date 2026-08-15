package com.waylo.overlay

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.view.MotionEvent
import android.view.View

/**
 * Persistent, touchable red "Next" button pinned to the right edge while
 * guidance runs. Tapping it force-advances to the next step — the reliable
 * manual override for when auto-advance can't tell the user has acted (e.g. a
 * video player that emits no accessibility click, or the app-open step). This
 * replaces the deprecated correction-flow mic button.
 */
class NextButtonView(context: Context) : View(context) {

    var onTap: (() -> Unit)? = null

    private val dp = resources.displayMetrics.density
    private val side = 62 * dp
    private val pad = 6 * dp
    private val totalSize = (side + pad * 2).toInt()

    private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.rgb(220, 38, 38)   // strong red (#DC2626), matches the dotted box
        style = Paint.Style.FILL
    }
    private val borderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(230, 245, 245, 240) // soft off-white ring for contrast on any app
        style = Paint.Style.STROKE
        strokeWidth = 3 * dp
    }
    private val glyphPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        style = Paint.Style.STROKE
        strokeWidth = 7 * dp
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }
    private val labelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        textSize = 11 * dp
        textAlign = Paint.Align.CENTER
        isFakeBoldText = true
    }

    init { setLayerType(LAYER_TYPE_SOFTWARE, null) }

    fun centerOffsetX(): Int = totalSize / 2
    fun centerOffsetY(): Int = totalSize / 2

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        setMeasuredDimension(totalSize, totalSize)
    }

    override fun onDraw(canvas: Canvas) {
        val cx = width / 2f
        val cy = height / 2f
        val r = 18 * dp
        val rect = RectF(cx - side / 2, cy - side / 2, cx + side / 2, cy + side / 2)
        canvas.drawRoundRect(rect, r, r, fillPaint)
        canvas.drawRoundRect(rect, r, r, borderPaint)

        // Right-pointing chevron ">" (the universal "next"), lifted to leave room for the label.
        val a = 11 * dp
        val oy = -7 * dp
        val path = Path().apply {
            moveTo(cx - a / 2, cy - a + oy)
            lineTo(cx + a / 2, cy + oy)
            lineTo(cx - a / 2, cy + a + oy)
        }
        canvas.drawPath(path, glyphPaint)
        canvas.drawText("NEXT", cx, cy + side / 2 - 9 * dp, labelPaint)
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
