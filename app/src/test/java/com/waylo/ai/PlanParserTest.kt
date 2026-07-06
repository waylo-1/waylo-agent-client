package com.waylo.ai

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Guards PlanParser against silent breakage from R8/minification (data class
 * fields it relies on must survive shrinking+obfuscation in the release build).
 */
class PlanParserTest {

    @Test
    fun `parses a full enriched plan response`() {
        val json = """
            {
              "success": true,
              "appPackage": "com.google.android.youtube",
              "appName": "YouTube",
              "language": "en",
              "totalSteps": 1,
              "steps": [
                {
                  "stepNumber": 1,
                  "instruction": "Open YouTube app",
                  "findDescription": "youtube app icon",
                  "elementType": "APP_ICON",
                  "screenRegion": "center",
                  "visualDescription": "red play button icon",
                  "alternateLabels": ["YT", "youtube"],
                  "fallbackHint": "scroll down and tap",
                  "parentContainer": "home screen"
                }
              ]
            }
        """.trimIndent()

        val plan = PlanParser.parse(json)

        assertNotNull(plan)
        assertEquals("com.google.android.youtube", plan!!.appPackage)
        assertEquals("YouTube", plan.appName)
        assertNull(plan.error)
        assertEquals(1, plan.steps.size)

        val step = plan.steps[0]
        assertEquals(1, step.index)
        assertEquals("Open YouTube app", step.instruction)
        assertEquals("youtube app icon", step.findDescription)
        assertEquals("APP_ICON", step.elementType)
        assertEquals("center", step.screenRegion)
        assertEquals("red play button icon", step.visualDescription)
        assertEquals(listOf("YT", "youtube"), step.alternateLabels)
        assertEquals("scroll down and tap", step.fallbackHint)
        assertEquals("home screen", step.parentContainer)
    }

    @Test
    fun `parses an older cached plan missing enriched fields without crashing`() {
        val json = """
            {
              "success": true,
              "appPackage": "com.instagram.android",
              "appName": "Instagram",
              "steps": [
                { "stepNumber": 1, "instruction": "Open Instagram", "findDescription": "instagram icon" }
              ]
            }
        """.trimIndent()

        val plan = PlanParser.parse(json)

        assertNotNull(plan)
        val step = plan!!.steps[0]
        assertEquals("instagram icon", step.findDescription)
        assertNull(step.elementType)
        assertNull(step.screenRegion)
        assertTrue(step.alternateLabels.isEmpty())
    }

    @Test
    fun `surfaces backend failure with error and errorDetail`() {
        val json = """
            {
              "success": false,
              "error": "Failed to generate plan",
              "details": "Too many tokens per day"
            }
        """.trimIndent()

        val plan = PlanParser.parse(json)

        assertNotNull(plan)
        assertTrue(plan!!.steps.isEmpty())
        assertEquals("Failed to generate plan", plan.error)
        assertEquals("Too many tokens per day", plan.errorDetail)
    }

    @Test
    fun `returns null on unparseable JSON`() {
        assertNull(PlanParser.parse("not json at all"))
    }
}
