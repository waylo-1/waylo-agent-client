package com.waylo.billing

import android.content.Context

/**
 * Freemium gate: the first [FREE_LIMIT] guidance tasks are free, after which the
 * user must upgrade to Pro (₹99/month) to keep going. State is a tiny bit of
 * SharedPreferences on-device — deliberately simple for launch; a server-backed
 * entitlement check can replace [isPro] later without changing call sites.
 */
object EntitlementManager {

    /** Number of free tasks before the paywall. */
    const val FREE_LIMIT = 5

    /** Collection UPI ID for the ₹99 upgrade. */
    const val UPI_ID = "shambhvis@icici"
    const val UPI_PAYEE_NAME = "Waylo"
    const val PRICE_INR = 99

    private const val PREFS = "waylo_entitlement"
    private const val KEY_USED = "free_tasks_used"
    private const val KEY_PRO = "is_pro"

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun freeTasksUsed(context: Context): Int = prefs(context).getInt(KEY_USED, 0)

    fun isPro(context: Context): Boolean = prefs(context).getBoolean(KEY_PRO, false)

    fun freeTasksRemaining(context: Context): Int =
        (FREE_LIMIT - freeTasksUsed(context)).coerceAtLeast(0)

    /** True while the user may start another task (still within the free allowance, or Pro). */
    fun canStartTask(context: Context): Boolean =
        isPro(context) || freeTasksUsed(context) < FREE_LIMIT

    /** Count a task against the free allowance. No-op for Pro users. */
    fun recordTaskStarted(context: Context) {
        if (isPro(context)) return
        prefs(context).edit().putInt(KEY_USED, freeTasksUsed(context) + 1).apply()
    }

    /** Unlock (or re-lock) unlimited access. */
    fun setPro(context: Context, pro: Boolean) {
        prefs(context).edit().putBoolean(KEY_PRO, pro).apply()
    }
}
