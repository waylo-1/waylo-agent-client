package com.sahayak.voice

import android.content.Context
import android.speech.tts.TextToSpeech
import android.util.Log
import java.util.Locale
import java.util.UUID

/**
 * Hindi Text-to-Speech wrapper. Speaks instructions aloud to the user.
 *
 * Falls back to English if a Hindi voice is not installed on the device.
 */
class Speaker(context: Context) : TextToSpeech.OnInitListener {

    companion object {
        private const val TAG = "Sahayak"
    }

    private val tts: TextToSpeech = TextToSpeech(context.applicationContext, this)
    private var ready = false

    override fun onInit(status: Int) {
        if (status == TextToSpeech.SUCCESS) {
            val hindi = Locale("hi", "IN")
            val result = tts.setLanguage(hindi)
            if (result == TextToSpeech.LANG_MISSING_DATA ||
                result == TextToSpeech.LANG_NOT_SUPPORTED
            ) {
                Log.w(TAG, "Hindi TTS unavailable, falling back to English.")
                tts.language = Locale.ENGLISH
            } else {
                Log.d(TAG, "Hindi TTS ready.")
            }
            ready = true
        } else {
            Log.e(TAG, "TTS initialisation failed with status=$status")
        }
    }

    /** Speak [text] immediately, flushing anything currently queued. */
    fun speak(text: String) {
        if (!ready) {
            Log.w(TAG, "speak() called before TTS ready.")
            return
        }
        tts.speak(text, TextToSpeech.QUEUE_FLUSH, null, UUID.randomUUID().toString())
    }

    /** Add [text] to the end of the speech queue. */
    fun speakQueued(text: String) {
        if (!ready) {
            Log.w(TAG, "speakQueued() called before TTS ready.")
            return
        }
        tts.speak(text, TextToSpeech.QUEUE_ADD, null, UUID.randomUUID().toString())
    }

    fun stop() {
        tts.stop()
    }

    fun shutdown() {
        tts.shutdown()
    }

    fun isSpeaking(): Boolean = tts.isSpeaking
}
