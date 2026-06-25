package com.waylo.data

import android.content.Context
import android.util.Log
import com.waylo.ai.GeminiClient
import com.waylo.ai.PlanParser
import java.security.MessageDigest

/**
 * Single source of truth for fetching a step plan, with a cost-minimising
 * lookup order:
 *
 *   1. Pre-built bundled guides (assets/guides.json) — zero cost, instant.
 *   2. On-device Room cache — zero cost, repeat tasks.
 *   3. Backend /plan (server cache → Nova Micro) — one cheap call, then cached.
 *
 * Must be initialised once (see [init]) before [getPlan] is called.
 */
object PlanRepository {

    private const val TAG = "WAYLO_DOT"
    private const val TTL_MS = 7L * 24 * 60 * 60 * 1000 // 7 days

    private lateinit var appContext: Context

    /** Call once from Application.onCreate. */
    fun init(context: Context) {
        appContext = context.applicationContext
    }

    private fun ready(): Boolean = this::appContext.isInitialized

    /**
     * Resolve a plan for [task], cheapest source first. Falls back to the
     * backend and caches the result locally.
     */
    suspend fun getPlan(task: String): PlanParser.Plan {
        // 1. Bundled pre-built guides.
        if (ready()) {
            PrebuiltGuides.find(appContext, task)?.let { return it }
        }

        val hash = taskHash(task)

        // 2. On-device Room cache.
        if (ready()) {
            try {
                val dao = WayloDatabase.get(appContext).planDao()
                dao.evictOlderThan(System.currentTimeMillis() - TTL_MS)
                val cached = dao.get(hash)
                if (cached != null) {
                    val plan = PlanParser.parse(cached.planJson)
                    if (plan.steps.isNotEmpty()) {
                        dao.incrementHit(hash)
                        Log.e(TAG, "PlanRepository: Room cache HIT for '$task'")
                        return plan
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "PlanRepository: Room read failed: ${e.message}")
            }
        }

        // 3. Backend.
        val plan = GeminiClient.getEnrichedPlan(task)

        // Cache the fresh plan for next time.
        if (ready() && plan.steps.isNotEmpty()) {
            try {
                WayloDatabase.get(appContext).planDao().upsert(
                    CachedPlan(
                        taskHash = hash,
                        appPackage = plan.appPackage,
                        planJson = PlanParser.toJson(plan),
                        cachedAt = System.currentTimeMillis(),
                        hitCount = 0
                    )
                )
            } catch (e: Exception) {
                Log.w(TAG, "PlanRepository: Room write failed: ${e.message}")
            }
        }

        return plan
    }

    /** SHA-256 of the normalised task string. */
    private fun taskHash(task: String): String {
        val normalized = task.lowercase().trim()
        val bytes = MessageDigest.getInstance("SHA-256").digest(normalized.toByteArray())
        return bytes.joinToString("") { "%02x".format(it) }
    }
}
