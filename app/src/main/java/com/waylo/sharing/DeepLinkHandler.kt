// TODO: Day 17 — implement handling of incoming guide deep links so the parent
// can open a shared link and have the guide start automatically.
package com.waylo.sharing

import android.net.Uri

/**
 * Parses incoming deep links (e.g. https://waylo.app/guide/<id>) and triggers
 * the matching guide to start.
 */
object DeepLinkHandler {

    /** TODO: Day 17 — extract a guide id from an incoming link Uri. */
    fun extractGuideId(uri: Uri?): String? {
        // TODO
        return null
    }
}
