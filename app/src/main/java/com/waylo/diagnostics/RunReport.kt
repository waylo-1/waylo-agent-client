package com.waylo.diagnostics

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import com.waylo.ai.Step
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedWriter
import java.io.File
import java.io.FileWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Per-run on-device debug report.
 *
 * Every guidance run writes a crash-safe JSONL timeline to the app's external
 * files dir, so a full run can be pulled and analysed without scraping giant
 * `adb logcat` dumps:
 *
 *     /sdcard/Android/data/com.waylo/files/reports/run_<ts>_<sid>.jsonl
 *
 * Line 1 is a `meta` record (task, device, launcher, the entire plan). Every
 * WAYLO_VERIFY event (routed here by [WayloVerify]) appends one `event`
 * record. [endRun] appends a final `end` record and refreshes `latest.md`, a
 * short human-readable digest of the most recent run.
 *
 * Design rules:
 *  - Report I/O must NEVER crash or slow guidance: every write is wrapped and
 *    any failure is logged and swallowed (reporting silently disables itself
 *    for the run rather than propagating).
 *  - Every line is flushed immediately so a run killed mid-flight (app swiped
 *    away, process death) still leaves a complete, analysable timeline — only
 *    the final `end`/digest are missing in that case.
 *  - All public entry points are serialised on [lock]; events arrive from
 *    several coroutines/dispatchers.
 */
object RunReport {

    private const val TAG = "WAYLO_REPORT"
    private const val DIR = "reports"

    /** Cap the in-memory copy kept for the Markdown digest; the JSONL on disk is unbounded and authoritative. */
    private const val MAX_EVENTS_IN_MEMORY = 6000

    /** Headline events surfaced in latest.md (prefix match on the message). */
    private val DIGEST_PREFIXES = listOf(
        "STEP_START", "DOT_PLACED", "DOT_CLAMPED", "ADVANCE_CHECK", "WRONG_LOCATION",
        "LOOKAHEAD_SKIP", "PARTIAL_MATCH", "VISION_CALL", "VISION", "PERIODIC_RESCAN"
    )

    private val lock = Any()
    private val fileStamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US)
    private val isoStamp = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSZ", Locale.US)

    private var writer: BufferedWriter? = null
    private var reportDir: File? = null
    private var currentFile: File? = null
    private var meta: JSONObject? = null
    private var startMs = 0L
    private var eventCount = 0
    private val recent = ArrayList<Pair<Long, String>>()

    /** True while a run is open and events are being recorded. */
    val isActive: Boolean get() = synchronized(lock) { writer != null }

    /**
     * Open a fresh report for a guidance run. Any run left open (e.g. the
     * previous task never reached a clean end) is finalised as `superseded`
     * first so its file is still valid.
     */
    fun startRun(
        context: Context,
        sessionId: String,
        task: String,
        steps: List<Step>,
        appPackage: String?,
        appName: String?
    ) = synchronized(lock) {
        endRunLocked("superseded")
        try {
            val dir = File(context.getExternalFilesDir(null), DIR).apply { mkdirs() }
            reportDir = dir
            val file = File(dir, "run_${fileStamp.format(Date())}_${sessionId.take(8)}.jsonl")
            val w = BufferedWriter(FileWriter(file, false))
            writer = w
            currentFile = file
            startMs = System.currentTimeMillis()
            eventCount = 0
            recent.clear()

            val metaObj = JSONObject().apply {
                put("type", "meta")
                put("schema", 1)
                put("sessionId", sessionId)
                put("task", task)
                put("appPackage", appPackage ?: JSONObject.NULL)
                put("appName", appName ?: JSONObject.NULL)
                put("startedAt", isoStamp.format(Date(startMs)))
                put("device", deviceInfo(context))
                put("launcherPackage", launcherPackage(context) ?: JSONObject.NULL)
                put("steps", stepsJson(steps))
            }
            meta = metaObj
            w.write(metaObj.toString()); w.newLine(); w.flush()
            Log.i(TAG, "Run report started: ${file.absolutePath}")
        } catch (e: Exception) {
            Log.w(TAG, "startRun failed (${e.message}) — reporting disabled for this run")
            closeQuietly()
        }
    }

    /** Append one event line. No-op when no run is open (e.g. demo/idle logging). */
    fun event(msg: String) {
        synchronized(lock) {
            val w = writer ?: return
            try {
                val t = System.currentTimeMillis() - startMs
                if (recent.size < MAX_EVENTS_IN_MEMORY) recent.add(t to msg)
                eventCount++
                val obj = JSONObject().apply {
                    put("type", "event")
                    put("tMs", t)
                    put("msg", msg)
                }
                w.write(obj.toString()); w.newLine(); w.flush()
            } catch (e: Exception) {
                Log.w(TAG, "event write failed: ${e.message}")
            }
        }
    }

    /** Finalise the current run with an [outcome] (completed / stopped / error / superseded). */
    fun endRun(outcome: String) = synchronized(lock) { endRunLocked(outcome) }

    private fun endRunLocked(outcome: String) {
        if (writer == null) return
        val durationMs = System.currentTimeMillis() - startMs
        try {
            val end = JSONObject().apply {
                put("type", "end")
                put("outcome", outcome)
                put("durationMs", durationMs)
                put("events", eventCount)
            }
            writer?.write(end.toString()); writer?.newLine(); writer?.flush()
        } catch (e: Exception) {
            Log.w(TAG, "endRun write failed: ${e.message}")
        } finally {
            closeQuietly()
        }
        try { writeDigest(outcome, durationMs) } catch (e: Exception) { Log.w(TAG, "digest failed: ${e.message}") }
    }

    private fun closeQuietly() {
        try { writer?.flush(); writer?.close() } catch (_: Exception) {}
        writer = null
    }

    // --- report content helpers ---

    private fun stepsJson(steps: List<Step>): JSONArray = JSONArray().apply {
        steps.forEach { s ->
            put(JSONObject().apply {
                put("index", s.index)
                put("instruction", s.instruction)
                put("findDescription", s.findDescription)
                put("elementType", s.elementType ?: JSONObject.NULL)
                put("screenRegion", s.screenRegion ?: JSONObject.NULL)
                put("visualDescription", s.visualDescription ?: JSONObject.NULL)
                put("alternateLabels", JSONArray(s.alternateLabels))
                put("fallbackHint", s.fallbackHint ?: JSONObject.NULL)
            })
        }
    }

    private fun deviceInfo(context: Context): JSONObject {
        val dm = context.resources.displayMetrics
        return JSONObject().apply {
            put("manufacturer", Build.MANUFACTURER)
            put("brand", Build.BRAND)
            put("model", Build.MODEL)
            put("device", Build.DEVICE)
            put("sdkInt", Build.VERSION.SDK_INT)
            put("release", Build.VERSION.RELEASE)
            put("screenWidthPx", dm.widthPixels)
            put("screenHeightPx", dm.heightPixels)
            put("density", dm.density)
        }
    }

    private fun launcherPackage(context: Context): String? = try {
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
        context.packageManager
            .resolveActivity(intent, PackageManager.MATCH_DEFAULT_ONLY)
            ?.activityInfo?.packageName
    } catch (e: Exception) {
        null
    }

    /**
     * Write `latest.md` — a short, human-scannable digest of the run just
     * finished. Best-effort: it renders the header from [meta] and a filtered
     * chronological list of headline events, so it never depends on fragile
     * per-field parsing of the log strings.
     */
    private fun writeDigest(outcome: String, durationMs: Long) {
        val dir = reportDir ?: return
        val m = meta
        val sb = StringBuilder()
        sb.append("# Waylo run report\n\n")
        if (m != null) {
            sb.append("- **Task:** ").append(m.optString("task")).append('\n')
            sb.append("- **App:** ").append(m.optString("appName", "?"))
                .append(" (").append(m.optString("appPackage", "?")).append(")\n")
            val d = m.optJSONObject("device")
            if (d != null) {
                sb.append("- **Device:** ").append(d.optString("manufacturer")).append(' ')
                    .append(d.optString("model")).append(" · Android ").append(d.optString("release"))
                    .append(" (API ").append(d.optInt("sdkInt")).append(") · ")
                    .append(d.optInt("screenWidthPx")).append('x').append(d.optInt("screenHeightPx")).append('\n')
            }
            sb.append("- **Launcher:** ").append(m.optString("launcherPackage", "?")).append('\n')
            sb.append("- **Session:** ").append(m.optString("sessionId")).append('\n')
        }
        sb.append("- **Outcome:** ").append(outcome)
            .append(" · ").append(durationMs).append("ms · ").append(eventCount).append(" events\n")
        currentFile?.let { sb.append("- **Full log:** ").append(it.name).append('\n') }

        m?.optJSONArray("steps")?.let { steps ->
            sb.append("\n## Plan (").append(steps.length()).append(" steps)\n\n")
            for (i in 0 until steps.length()) {
                val s = steps.optJSONObject(i) ?: continue
                sb.append(s.optInt("index")).append(". ")
                    .append(s.optString("instruction"))
                    .append("  _[").append(s.optString("elementType", "?")).append("]_\n")
            }
        }

        sb.append("\n## Timeline (headline events)\n\n")
        var shown = 0
        for ((t, msg) in recent) {
            if (DIGEST_PREFIXES.none { msg.startsWith(it) }) continue
            sb.append("- `+").append(t).append("ms` ").append(msg).append('\n')
            shown++
        }
        if (shown == 0) sb.append("_(no headline events captured)_\n")

        try {
            File(dir, "latest.md").writeText(sb.toString())
        } catch (e: Exception) {
            Log.w(TAG, "latest.md write failed: ${e.message}")
        }
    }
}
