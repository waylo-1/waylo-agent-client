package com.waylo.voice

import android.content.Context
import android.content.Intent
import android.speech.tts.TextToSpeech
import android.util.Log
import java.util.Locale
import java.util.UUID

/**
 * English Text-to-Speech wrapper with guaranteed-safe initialisation.
 *
 * Calls to [speak] before the engine has finished initialising are queued and
 * flushed automatically once [onInit] reports success. This prevents the common
 * "nothing is spoken" bug where speak() is invoked before the engine is ready.
 */
class Speaker(private val context: Context) : TextToSpeech.OnInitListener {

    companion object {
        private const val TAG = "Waylo"

        /**
         * Returns true if at least one TTS engine is installed on the device.
         * Use this to warn the user when no engine is available.
         */
        fun isTtsAvailable(context: Context): Boolean {
            val intent = Intent(TextToSpeech.Engine.ACTION_CHECK_TTS_DATA)
            val resolved = context.packageManager.queryIntentActivities(intent, 0)
            return resolved.isNotEmpty()
        }
    }

    private var tts: TextToSpeech? = null
    private var isReady = false
    private val pendingQueue = mutableListOf<String>()

    init {
        tts = TextToSpeech(context, this)
    }

    override fun onInit(status: Int) {
        if (status == TextToSpeech.SUCCESS) {
            val result = tts?.setLanguage(Locale.ENGLISH)
            if (result == TextToSpeech.LANG_MISSING_DATA ||
                result == TextToSpeech.LANG_NOT_SUPPORTED
            ) {
                Log.w(TAG, "English TTS not supported, using default")
            }
            isReady = true
            // Flush anything queued before init finished.
            pendingQueue.forEach { speakNow(it) }
            pendingQueue.clear()
        } else {
            Log.e(TAG, "TTS init failed with status: $status")
        }
    }

    /** Speak [text] immediately, or queue it if the engine isn't ready yet. */
    fun speak(text: String) {
        if (isReady) speakNow(text) else pendingQueue.add(text)
    }

    /** Add [text] to the end of the speech queue (or pending queue if not ready). */
    fun speakQueued(text: String) {
        if (isReady) {
            tts?.speak(text, TextToSpeech.QUEUE_ADD, null, UUID.randomUUID().toString())
        } else {
            pendingQueue.add(text)
        }
    }

    private fun speakNow(text: String) {
        tts?.speak(text, TextToSpeech.QUEUE_FLUSH, null, UUID.randomUUID().toString())
    }

    fun stop() {
        tts?.stop()
    }

    fun shutdown() {
        tts?.shutdown()
        isReady = false
    }

    fun isSpeaking(): Boolean = tts?.isSpeaking ?: false
}
