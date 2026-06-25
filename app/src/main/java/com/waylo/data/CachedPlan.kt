package com.waylo.data

import androidx.room.Entity
import androidx.room.PrimaryKey

/**
 * A locally cached step plan for a task. Repeat tasks ("send a WhatsApp
 * message") are served from here with zero network/API cost.
 *
 * @param taskHash   SHA-256 of the normalised task string (primary key).
 * @param appPackage target app package, e.g. "com.whatsapp".
 * @param planJson   the full plan serialised via [com.waylo.ai.PlanParser.toJson].
 * @param cachedAt   epoch millis when stored.
 * @param hitCount   how many times this cache entry has been served.
 */
@Entity(tableName = "cached_plans")
data class CachedPlan(
    @PrimaryKey val taskHash: String,
    val appPackage: String,
    val planJson: String,
    val cachedAt: Long,
    val hitCount: Int
)
