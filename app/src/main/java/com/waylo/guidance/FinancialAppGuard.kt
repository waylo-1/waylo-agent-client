package com.waylo.guidance

import android.os.SystemClock
import android.util.Log
import android.widget.Toast
import com.waylo.accessibility.WayloAccessibilityService
import com.waylo.service.WayloGuidanceService

/**
 * Safety net for Indian financial/banking/payment apps. Waylo must never
 * place its overlay or attempt guidance inside these — many of them already
 * block accessibility-service overlays outright for good reason, and even
 * where they don't, an elderly user being "guided" through a money transfer
 * by an automated overlay is exactly the kind of scenario Waylo should stay
 * far away from.
 *
 * This does two things:
 *  - Watches foreground-package changes (fed by
 *    [com.waylo.accessibility.WayloAccessibilityService]) and pauses/resumes
 *    [GuidanceEngine] as the user enters/leaves one of these apps.
 *  - Lets [GuidanceEngine.start] short-circuit a task request before it ever
 *    reaches the backend, if the task text itself names one of these
 *    apps/services.
 *
 * The package list is a best-effort set of well-known apps (verified against
 * public app-store listings at time of writing) — it is not, and cannot
 * practically be, exhaustive of every Indian bank's app. Extend it as more
 * are identified.
 */
object FinancialAppGuard {

    private const val TAG = "WAYLO_DOT"

    /** Known Indian financial/banking/payment app packages. */
    val FINANCIAL_PACKAGES = setOf(
        "com.phonepe.app",                           // PhonePe
        "net.one97.paytm",                            // Paytm
        "com.google.android.apps.nbu.paisa.user",     // Google Pay (India)
        "in.org.npci.upiapp",                         // BHIM
        "com.sbi.lotusintouch",                       // SBI YONO
        "com.snapwork.hdfc",                          // HDFC Bank Mobile Banking
        "com.csam.icici.bank.imobile",                // ICICI iMobile Pay
        "com.axis.mobile",                            // Axis Mobile
        "com.msf.kbank.mobile",                       // Kotak Mobile Banking
        "com.dreamplug.androidapp"                    // CRED
    )

    /** Keywords that suggest a typed/spoken task names one of these apps/services. */
    private val FINANCIAL_KEYWORDS = listOf(
        "phonepe", "paytm", "google pay", "gpay", "g-pay", "bhim", "yono",
        "hdfc", "icici", "axis bank", "kotak", "cred",
        "upi", "net banking", "netbanking", "bank transfer", "money transfer"
    )

    private const val WARNING_MESSAGE =
        "I'm turning myself off so your banking app works safely. When you're done, open Waylo and turn me back on."

    /** After a re-enable, don't immediately turn off again if a banking-app event fires within this window (prevents an off/on loop). */
    private const val REDISABLE_COOLDOWN_MS = 15000L
    private var lastDisableAt = 0L
    private const val REFUSAL_MESSAGE =
        "For your safety, I can't guide you inside banking or payment apps. " +
            "Please ask someone you trust for help with that, or do it yourself carefully."

    private var pausedPackage: String? = null
    private var hasWarnedThisSession = false

    fun isFinancialPackage(pkg: String): Boolean = pkg in FINANCIAL_PACKAGES

    /** True if [task] appears to reference a known financial app/service by name. */
    fun mentionsFinancialApp(task: String): Boolean {
        val lower = task.lowercase()
        return FINANCIAL_KEYWORDS.any { lower.contains(it) }
    }

    /** The friendly, spoken/shown explanation for refusing a task that mentions a financial app. */
    fun refusalMessage(): String = REFUSAL_MESSAGE

    /**
     * Called from [com.waylo.accessibility.WayloAccessibilityService] on every
     * foreground-package change. Pauses guidance the moment a financial app
     * comes to the foreground, and resumes it once the user leaves.
     */
    fun onForegroundPackageChanged(pkg: String) {
        val nowFinancial = isFinancialPackage(pkg)
        if (nowFinancial && pausedPackage == null) {
            pausedPackage = pkg
            Log.d(TAG, "FinancialAppGuard: entered $pkg")
            GuidanceEngine.pauseForFinancialApp()

            // Just re-enabled moments ago (e.g. the user turned Waylo back on
            // while a banking event was still firing) — don't loop straight
            // back into disabling it.
            val now = SystemClock.elapsedRealtime()
            if (now - lastDisableAt < REDISABLE_COOLDOWN_MS) {
                Log.d(TAG, "FinancialAppGuard: within re-disable cooldown, leaving accessibility on.")
                return
            }
            lastDisableAt = now

            if (!hasWarnedThisSession) {
                hasWarnedThisSession = true
                WayloGuidanceService.instance?.let { service ->
                    Toast.makeText(service, WARNING_MESSAGE, Toast.LENGTH_LONG).show()
                    service.speaker.speak(WARNING_MESSAGE)
                    service.showReEnableAccessibilityNotification()
                }
            }
            // Turn the accessibility service off so the banking app isn't
            // blocked. This ends event delivery, so the user re-enables Waylo
            // manually (one tap via the notification) when they're done.
            WayloAccessibilityService.instance?.disableForFinancialApp()
        } else if (!nowFinancial && pausedPackage != null) {
            Log.d(TAG, "FinancialAppGuard: resuming — left ${pausedPackage}, now in $pkg")
            pausedPackage = null
            hasWarnedThisSession = false
            GuidanceEngine.resumeAfterFinancialApp()
        }
    }
}
