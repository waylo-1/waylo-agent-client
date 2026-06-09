package com.waylo.guidance

import com.waylo.ai.Step

/**
 * Hardcoded multi-step demo tasks. These prove the full guidance loop end to
 * end without needing the AI backend (which arrives in Week 2).
 */
object DemoTasks {

    val takeAPhoto = listOf(
        Step(1, "Tap the Camera app on your home screen", "Camera"),
        Step(2, "Tap the shutter button to take the photo", "shutter button"),
        Step(3, "Tap OK to save the photo", "OK save")
    )

    val openWhatsApp = listOf(
        Step(1, "Tap the WhatsApp app on your home screen", "WhatsApp"),
        Step(2, "Tap the green chat button to start a new message", "new chat compose"),
        Step(3, "Search for the contact you want to message", "search contacts")
    )

    val openYouTube = listOf(
        Step(1, "Tap the YouTube app on your home screen", "YouTube"),
        Step(2, "Tap the search icon at the top", "search"),
        Step(3, "Type what you want to watch", "search bar input")
    )
}
