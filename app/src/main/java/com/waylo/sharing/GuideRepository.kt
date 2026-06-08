// TODO: Day 17 — implement fetch/store of shareable guides via the backend
// (POST /guide, GET /guide/:id).
package com.waylo.sharing

import com.waylo.ai.Step

/**
 * Stores and retrieves shareable guides through the backend so a child can
 * generate a link that starts the guide on their parent's phone.
 */
object GuideRepository {

    /** TODO: Day 17 — POST /guide, return the shareable id/url. */
    suspend fun saveGuide(task: String, steps: List<Step>): String? {
        // TODO
        return null
    }

    /** TODO: Day 17 — GET /guide/:id, return the stored plan. */
    suspend fun fetchGuide(id: String): List<Step> {
        // TODO
        return emptyList()
    }
}
