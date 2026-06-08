// TODO: Day 20-21 — implement SpeechRecognizer for task entry and mid-flow Q&A
// (hold the dot -> mic opens -> Gemini answers -> continue).
package com.waylo.voice

import android.content.Context

/**
 * Handles voice input: speech-to-text for task entry, and the mid-flow Q&A
 * interaction when the user holds the dot to ask a question.
 */
class MicHandler(private val context: Context) {

    /** TODO: Day 20 — start speech recognition, return recognised text. */
    fun startListening(onResult: (String) -> Unit) {
        // TODO
    }

    /** TODO: Day 21 — stop listening and release the recognizer. */
    fun stop() {
        // TODO
    }
}
