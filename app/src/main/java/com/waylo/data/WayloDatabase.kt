package com.waylo.data

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase

/** Room database for Waylo's on-device caches. */
@Database(entities = [CachedPlan::class], version = 1, exportSchema = false)
abstract class WayloDatabase : RoomDatabase() {

    abstract fun planDao(): PlanDao

    companion object {
        @Volatile
        private var INSTANCE: WayloDatabase? = null

        fun get(context: Context): WayloDatabase =
            INSTANCE ?: synchronized(this) {
                INSTANCE ?: Room.databaseBuilder(
                    context.applicationContext,
                    WayloDatabase::class.java,
                    "waylo.db"
                ).fallbackToDestructiveMigration().build().also { INSTANCE = it }
            }
    }
}
