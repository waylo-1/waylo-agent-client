package com.waylo.diagnostics

import android.util.Log

/**
 * Single sink for the `WAYLO_VERIFY` structured instrumentation stream.
 *
 * Every call still writes to Logcat exactly as before (tag `WAYLO_VERIFY`,
 * level `d`), so existing `adb logcat -s WAYLO_VERIFY` workflows are
 * unchanged — and the same line is also handed to [RunReport], which captures
 * it into the current run's on-device JSONL timeline when a run is active
 * (a no-op otherwise). This is the drop-in replacement for the old
 * `Log.d("WAYLO_VERIFY", msg)` call sites.
 */
object WayloVerify {

    private const val TAG = "WAYLO_VERIFY"

    fun d(msg: String) {
        Log.d(TAG, msg)
        RunReport.event(msg)
    }
}
