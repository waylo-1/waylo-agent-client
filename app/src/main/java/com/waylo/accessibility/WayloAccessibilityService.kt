package com.waylo.accessibility

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

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
    }

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

        // A window state change means the user navigated (likely by tapping the
        // real button under the dot). Let guidance advance to the next step.
        if (event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
            com.waylo.guidance.GuidanceEngine.onWindowChanged(pkg)
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
