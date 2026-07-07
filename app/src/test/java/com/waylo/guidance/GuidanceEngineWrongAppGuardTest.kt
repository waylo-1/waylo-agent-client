package com.waylo.guidance

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Covers GuidanceEngine.isInExpectedApp(), the guard that stops the dot from
 * being placed/referenced while the user is in a different app than the
 * current step expects — e.g. a stray match from a screen the user
 * wandered off to shouldn't get the dot.
 */
class GuidanceEngineWrongAppGuardTest {

    @Test
    fun `step 0 is satisfied by any launcher package`() {
        assertTrue(GuidanceEngine.isInExpectedApp(0, "com.android.launcher3", null))
        assertTrue(GuidanceEngine.isInExpectedApp(0, "com.google.android.apps.nexuslauncher", "com.google.android.youtube"))
    }

    @Test
    fun `step 0 fails when foreground is a non-launcher app`() {
        assertFalse(GuidanceEngine.isInExpectedApp(0, "com.google.android.youtube", "com.google.android.youtube"))
    }

    @Test
    fun `later step matches when foreground equals the expected app`() {
        assertTrue(GuidanceEngine.isInExpectedApp(1, "com.google.android.youtube", "com.google.android.youtube"))
    }

    @Test
    fun `later step fails when foreground is a different app`() {
        assertFalse(GuidanceEngine.isInExpectedApp(1, "com.whatsapp", "com.google.android.youtube"))
    }

    @Test
    fun `later step passes when there is no known expected package (older or cached plan)`() {
        assertTrue(GuidanceEngine.isInExpectedApp(1, "com.whatsapp", null))
    }

    @Test
    fun `fails open when we have no foreground signal at all yet`() {
        assertTrue(GuidanceEngine.isInExpectedApp(0, null, "com.google.android.youtube"))
        assertTrue(GuidanceEngine.isInExpectedApp(1, null, "com.google.android.youtube"))
    }
}
