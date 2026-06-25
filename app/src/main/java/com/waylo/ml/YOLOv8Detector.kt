package com.waylo.ml

import android.content.Context
import android.graphics.Bitmap
import android.graphics.RectF
import android.util.Log
import com.waylo.guidance.ElementType
import com.waylo.guidance.SemanticMatcher
import com.waylo.guidance.StepMetadata
import org.tensorflow.lite.Interpreter
import org.tensorflow.lite.gpu.CompatibilityList
import org.tensorflow.lite.gpu.GpuDelegate
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.MappedByteBuffer
import java.nio.channels.FileChannel

/**
 * L2 detector: YOLOv8-nano fine-tuned on RICO UI screenshots, exported to
 * TFLite and bundled in the APK (assets/ui_detector.tflite + ui_labels.txt).
 *
 * Runs fully on-device (~30-150ms depending on hardware), zero API cost. Used
 * when L0 (accessibility tree) and L1 (OCR) both miss — typically icon-only
 * buttons and custom/Compose elements with no text label.
 *
 * Gracefully no-ops if the model asset is not present (so the app builds and
 * runs before the model is trained/shipped): [isAvailable] is false and
 * [detect] returns an empty list.
 */
class YOLOv8Detector private constructor(
    private val interpreter: Interpreter,
    private val gpuDelegate: GpuDelegate?,
    private val labels: List<String>,
    private val inputSize: Int
) {

    data class DetectedElement(
        val type: String,      // label, e.g. "BUTTON"
        val bbox: RectF,       // in source-bitmap pixel coordinates
        val confidence: Float
    )

    /** Run detection over [bitmap]. Returns boxes in bitmap pixel coordinates. */
    fun detect(bitmap: Bitmap): List<DetectedElement> {
        return try {
            val input = preprocess(bitmap)
            val outShape = interpreter.getOutputTensor(0).shape() // [1, 4+nc, N]
            val channels = outShape[1]
            val numBoxes = outShape[2]
            val output = Array(1) { Array(channels) { FloatArray(numBoxes) } }
            interpreter.run(input, output)
            decode(output[0], channels, numBoxes, bitmap.width, bitmap.height)
        } catch (e: Exception) {
            Log.w(TAG, "YOLO detect failed: ${e.message}")
            emptyList()
        }
    }

    /**
     * Convenience for the guidance pipeline: pick the detection that best
     * matches [step]'s elementType and screen region, returning its centre in
     * bitmap (≈ screen) pixel coordinates, or null.
     */
    fun findBest(
        bitmap: Bitmap,
        step: StepMetadata,
        screenWidth: Int,
        screenHeight: Int
    ): Pair<Int, Int>? {
        val detections = detect(bitmap)
        if (detections.isEmpty()) return null

        val wantedLabels = labelsFor(step.elementType)
        var best: DetectedElement? = null
        var bestScore = -1f
        for (d in detections) {
            // Type match is the primary signal; region match is a tiebreaker.
            val typeBonus = if (wantedLabels.isEmpty() || wantedLabels.contains(d.type)) 1f else 0.4f
            val box = android.graphics.Rect(
                d.bbox.left.toInt(), d.bbox.top.toInt(), d.bbox.right.toInt(), d.bbox.bottom.toInt()
            )
            val regionBonus =
                if (SemanticMatcher.isInRegion(box, step.screenRegion, screenWidth, screenHeight)) 1.2f else 1f
            val score = d.confidence * typeBonus * regionBonus
            if (score > bestScore) {
                bestScore = score
                best = d
            }
        }

        // Require a reasonable confidence after weighting.
        if (best == null || bestScore < MIN_WEIGHTED_SCORE) {
            Log.d(TAG, "YOLO findBest: no confident match (best=$bestScore)")
            return null
        }
        Log.d(TAG, "YOLO findBest: ${best.type} conf=${best.confidence} score=$bestScore")
        return Pair(best.bbox.centerX().toInt(), best.bbox.centerY().toInt())
    }

    /** Map a [StepMetadata] element type to candidate YOLO class labels. */
    private fun labelsFor(type: ElementType): Set<String> = when (type) {
        ElementType.BUTTON -> setOf("BUTTON")
        ElementType.ICON_BUTTON -> setOf("BUTTON", "IMAGE", "APP_ICON")
        ElementType.FAB -> setOf("FAB", "BUTTON")
        ElementType.TEXT_INPUT -> setOf("TEXT_INPUT")
        ElementType.NAV_ITEM -> setOf("NAV_ITEM")
        ElementType.TOGGLE -> setOf("TOGGLE", "CHECKBOX")
        ElementType.APP_ICON -> setOf("APP_ICON", "IMAGE")
        ElementType.LIST_ITEM -> setOf("TEXT_LABEL", "BUTTON")
        ElementType.IMAGE -> setOf("IMAGE")
        ElementType.TAB -> setOf("NAV_ITEM", "BUTTON")
        ElementType.OVERFLOW_MENU -> setOf("BUTTON", "IMAGE")
        ElementType.BACK_BUTTON -> setOf("BUTTON", "IMAGE")
        ElementType.OTHER -> emptySet()
    }

    /** Resize to inputSize and pack into the model's expected input buffer. */
    private fun preprocess(bitmap: Bitmap): ByteBuffer {
        val resized = Bitmap.createScaledBitmap(bitmap, inputSize, inputSize, true)
        val isFloat = interpreter.getInputTensor(0).dataType().name == "FLOAT32"
        val bytesPerChannel = if (isFloat) 4 else 1
        val buffer = ByteBuffer
            .allocateDirect(inputSize * inputSize * 3 * bytesPerChannel)
            .order(ByteOrder.nativeOrder())

        val pixels = IntArray(inputSize * inputSize)
        resized.getPixels(pixels, 0, inputSize, 0, 0, inputSize, inputSize)
        for (pixel in pixels) {
            val r = (pixel shr 16) and 0xFF
            val g = (pixel shr 8) and 0xFF
            val b = pixel and 0xFF
            if (isFloat) {
                buffer.putFloat(r / 255f)
                buffer.putFloat(g / 255f)
                buffer.putFloat(b / 255f)
            } else {
                buffer.put(r.toByte())
                buffer.put(g.toByte())
                buffer.put(b.toByte())
            }
        }
        if (resized != bitmap) resized.recycle()
        buffer.rewind()
        return buffer
    }

    /**
     * Decode ultralytics YOLOv8 output [4+nc, N] (boxes in xywh, model space)
     * into bitmap-space boxes, then run NMS.
     */
    private fun decode(
        out: Array<FloatArray>,
        channels: Int,
        numBoxes: Int,
        imgW: Int,
        imgH: Int
    ): List<DetectedElement> {
        val numClasses = channels - 4
        if (numClasses <= 0) return emptyList()
        val scaleX = imgW.toFloat() / inputSize
        val scaleY = imgH.toFloat() / inputSize

        val candidates = mutableListOf<DetectedElement>()
        for (n in 0 until numBoxes) {
            // Best class for this box.
            var bestCls = -1
            var bestConf = 0f
            for (c in 0 until numClasses) {
                val score = out[4 + c][n]
                if (score > bestConf) {
                    bestConf = score
                    bestCls = c
                }
            }
            if (bestConf < CONF_THRESHOLD || bestCls < 0) continue

            val cx = out[0][n] * scaleX
            val cy = out[1][n] * scaleY
            val w = out[2][n] * scaleX
            val h = out[3][n] * scaleY
            val rect = RectF(cx - w / 2f, cy - h / 2f, cx + w / 2f, cy + h / 2f)
            val label = labels.getOrElse(bestCls) { "OTHER" }
            candidates.add(DetectedElement(label, rect, bestConf))
        }
        return nms(candidates)
    }

    /** Greedy non-maximum suppression. */
    private fun nms(boxes: List<DetectedElement>): List<DetectedElement> {
        val sorted = boxes.sortedByDescending { it.confidence }.toMutableList()
        val kept = mutableListOf<DetectedElement>()
        while (sorted.isNotEmpty()) {
            val best = sorted.removeAt(0)
            kept.add(best)
            sorted.removeAll { iou(best.bbox, it.bbox) > IOU_THRESHOLD }
        }
        return kept
    }

    private fun iou(a: RectF, b: RectF): Float {
        val left = maxOf(a.left, b.left)
        val top = maxOf(a.top, b.top)
        val right = minOf(a.right, b.right)
        val bottom = minOf(a.bottom, b.bottom)
        val inter = maxOf(0f, right - left) * maxOf(0f, bottom - top)
        val areaA = (a.right - a.left) * (a.bottom - a.top)
        val areaB = (b.right - b.left) * (b.bottom - b.top)
        val union = areaA + areaB - inter
        return if (union <= 0f) 0f else inter / union
    }

    /** Release native resources. */
    fun close() {
        try { interpreter.close() } catch (_: Exception) {}
        try { gpuDelegate?.close() } catch (_: Exception) {}
    }

    companion object {
        private const val TAG = "Waylo"
        private const val MODEL_ASSET = "ui_detector.tflite"
        private const val LABELS_ASSET = "ui_labels.txt"
        private const val DEFAULT_INPUT = 640
        private const val CONF_THRESHOLD = 0.25f
        private const val IOU_THRESHOLD = 0.45f
        private const val MIN_WEIGHTED_SCORE = 0.30f

        /**
         * Build a detector, or null if the model asset is not bundled (the
         * pipeline then simply skips L2). Tries the GPU delegate, falls back
         * to multithreaded CPU.
         */
        fun create(context: Context): YOLOv8Detector? {
            val ctx = context.applicationContext
            if (!assetExists(ctx, MODEL_ASSET)) {
                Log.w(TAG, "YOLO: $MODEL_ASSET not bundled — L2 disabled.")
                return null
            }
            return try {
                val model = loadModel(ctx, MODEL_ASSET)
                var delegate: GpuDelegate? = null
                val options = Interpreter.Options().apply {
                    if (CompatibilityList().isDelegateSupportedOnThisDevice) {
                        delegate = GpuDelegate()
                        addDelegate(delegate)
                    } else {
                        setNumThreads(4)
                    }
                }
                val interpreter = Interpreter(model, options)
                val inputShape = interpreter.getInputTensor(0).shape() // [1, S, S, 3]
                val inputSize = if (inputShape.size >= 3) inputShape[1] else DEFAULT_INPUT
                val labels = loadLabels(ctx, LABELS_ASSET)
                Log.e("WAYLO_DOT", "YOLO: detector ready (input=$inputSize, classes=${labels.size})")
                YOLOv8Detector(interpreter, delegate, labels, inputSize)
            } catch (e: Exception) {
                Log.e(TAG, "YOLO: failed to init detector: ${e.message}", e)
                null
            }
        }

        private fun assetExists(context: Context, name: String): Boolean = try {
            context.assets.open(name).use { true }
        } catch (e: Exception) {
            false
        }

        private fun loadModel(context: Context, name: String): MappedByteBuffer {
            val fd = context.assets.openFd(name)
            FileInputStream(fd.fileDescriptor).use { fis ->
                val channel = fis.channel
                return channel.map(FileChannel.MapMode.READ_ONLY, fd.startOffset, fd.declaredLength)
            }
        }

        private fun loadLabels(context: Context, name: String): List<String> = try {
            context.assets.open(name).bufferedReader().useLines { lines ->
                lines.map { it.trim() }.filter { it.isNotEmpty() }.toList()
            }
        } catch (e: Exception) {
            emptyList()
        }
    }
}
