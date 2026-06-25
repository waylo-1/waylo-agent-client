package com.waylo.data

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query

@Dao
interface PlanDao {

    @Query("SELECT * FROM cached_plans WHERE taskHash = :taskHash LIMIT 1")
    suspend fun get(taskHash: String): CachedPlan?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(plan: CachedPlan)

    @Query("UPDATE cached_plans SET hitCount = hitCount + 1 WHERE taskHash = :taskHash")
    suspend fun incrementHit(taskHash: String)

    /** Evict entries older than [cutoff] (epoch millis). */
    @Query("DELETE FROM cached_plans WHERE cachedAt < :cutoff")
    suspend fun evictOlderThan(cutoff: Long)
}
