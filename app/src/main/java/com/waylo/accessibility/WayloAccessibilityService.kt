package com.waylo.accessibility

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.os.SystemClock
import android.util.Log
import android.view.KeyEvent
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import com.waylo.correction.CorrectionFlow

/**
 * Reads the UI tree of whatever app is currently on screen.
 *
 * This is the eyes of Waylo. Every other layer (ElementFinder, GuidanceEngine)
 * depends on the live node tree exposed here.
 *
 * Accessed as a singleton via [WayloAccessibilityService.instance]. The instance
 * is only non-null while the service is connected (i.e. the user has enabled it in
 * Settings > Accessibility).
 */
class WayloAccessibilityService : AccessibilityService() {

    companion object {
        private const val TAG = "Waylo"

        /** Live reference to the connected service, or null if not enabled. */
        @Volatile
        var instance: WayloAccessibilityService? = null
            private set

        /** Two volume-down presses this close together (ms) open the correction flow (see [CorrectionFlow]). */
        private const val DOUBLE_PRESS_WINDOW_MS = 800L
    }

    /** className from the most recent TYPE_WINDOW_STATE_CHANGED event — best-effort current Activity name, for correction-flow payloads. */
    @Volatile
    var lastActivityClassName: String? = null
        private set

    private var lastVolumeDownAt = 0L

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this

        // Respond to ALL event types across ALL packages, and retrieve full
        // interactive window content so we can read every node.
        serviceInfo = (serviceInfo ?: AccessibilityServiceInfo()).apply {
            eventTypes = AccessibilityEvent.TYPES_ALL_MASK
            feedbackType = AccessibilityServiceInfo.FEEDBACK_GENERIC
            flags = flags or
                AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS or
                AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS or
                AccessibilityServiceInfo.FLAG_REQUEST_FILTER_KEY_EVENTS
            notificationTimeout = 100
        }

        Log.d(TAG, "AccessibilityService connected. Watching all packages.")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        val pkg = event.packageName?.toString() ?: "unknown"
        val type = AccessibilityEvent.eventTypeToString(event.eventType)
        Log.d(TAG, "Event from [$pkg] type=$type")

        // GuidanceEngine picks which of these signals actually matter for the
        // current step's verification mode (APP_ICON/opening steps care about
        // window-state changes, tap-in-app steps about clicks/content changes,
        // TEXT_INPUT steps about text changes) — this service just forwards
        // the raw signal, checking the financial-app guard first so
        // entering/leaving a banking app pauses/resumes guidance before
        // GuidanceEngine acts on the same event.
        when (event.eventType) {
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED -> {
                lastActivityClassName = event.className?.toString()
                com.waylo.guidance.FinancialAppGuard.onForegroundPackageChanged(pkg)
                com.waylo.guidance.GuidanceEngine.onWindowStateChanged(pkg)
            }
            AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED -> {
                com.waylo.guidance.GuidanceEngine.onContentChanged(pkg)
            }
            AccessibilityEvent.TYPE_VIEW_CLICKED -> {
                // The correction flow's "capture the next tap as the correct
                // target" gets first look — it's a separate concern from
                // step-tap verification and must not be missed just because
                // GuidanceEngine's own onViewClicked also runs on this event.
                CorrectionFlow.onNodeClicked(event.source)
                com.waylo.guidance.GuidanceEngine.onViewClicked(event.source)
            }
            AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED -> {
                com.waylo.guidance.GuidanceEngine.onTextChanged(event.source)
            }
        }
    }

    /**
     * Requires [AccessibilityServiceInfo.FLAG_REQUEST_FILTER_KEY_EVENTS]
     * (set in [onServiceConnected]). Two KEYCODE_VOLUME_DOWN key-DOWN events
     * within [DOUBLE_PRESS_WINDOW_MS] of each other open the correction flow
     * and consume both key events (volume is not adjusted); a single press
     * is left alone (returns false) so normal volume control still works.
     */
    override fun onKeyEvent(event: KeyEvent?): Boolean {
        if (event?.keyCode != KeyEvent.KEYCODE_VOLUME_DOWN || event.action != KeyEvent.ACTION_DOWN) {
            return super.onKeyEvent(event)
        }
        val now = SystemClock.elapsedRealtime()
        val sinceLast = now - lastVolumeDownAt
        return if (sinceLast in 1..DOUBLE_PRESS_WINDOW_MS) {
            lastVolumeDownAt = 0L // consumed — a third rapid press starts a fresh pair, not a second trigger
            Log.d(TAG, "Volume-down double-press detected — opening correction flow.")
            CorrectionFlow.start()
            true
        } else {
            lastVolumeDownAt = now
            false
        }
    }

    /**
     * Turn the accessibility service OFF so a banking/UPI app — which refuses
     * to run while ANY accessibility service is enabled (an RBI-driven security
     * check) — can be used without the user hunting through Settings to disable
     * Waylo manually. Android does NOT allow an app to re-enable its own
     * accessibility service, so the user re-enables via the notification /
     * MainActivity when they return to Waylo (see [FinancialAppGuard]).
     */
    fun disableForFinancialApp() {
        Log.d(TAG, "Disabling accessibility so a banking app isn't blocked.")
        try {
            disableSelf()
        } catch (e: Exception) {
            Log.w(TAG, "disableSelf() failed: ${e.message}")
        }
    }

    override fun onInterrupt() {
        Log.d(TAG, "AccessibilityService interrupted.")
    }

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        Log.d(TAG, "AccessibilityService unbound.")
        instance = null
        return super.onUnbind(intent)
    }

    /**
     * Recursively flatten the entire active window into a list of every non-null node.
     * Each node is also logged at DEBUG level for inspection during development.
     */
    fun getAllNodes(): List<AccessibilityNodeInfo> {
        val result = mutableListOf<AccessibilityNodeInfo>()
        val root = rootInActiveWindow ?: return result
        flattenNode(root, result)
        Log.d(TAG, "getAllNodes() collected ${result.size} nodes.")
        return result
    }

    /**
     * Same as [getAllNodes] but filtered to a single package name.
     */
    fun getNodesForPackage(packageName: String): List<AccessibilityNodeInfo> {
        return getAllNodes().filter {
            it.packageName?.toString() == packageName
        }
    }

    /**
     * Depth-first traversal that appends every non-null node into [result] and logs
     * its key identifying attributes.
     */
    private fun flattenNode(
        node: AccessibilityNodeInfo,
        result: MutableList<AccessibilityNodeInfo>
    ) {
        result.add(node)
        Log.d(
            TAG,
            "Node: desc='${node.contentDescription}' " +
                "text='${node.text}' " +
                "id='${node.viewIdResourceName}' " +
                "class='${node.className}'"
        )
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            flattenNode(child, result)
        }
    }
}
