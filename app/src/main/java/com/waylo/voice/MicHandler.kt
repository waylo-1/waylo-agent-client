package com.waylo.voice

import android.content.Context
import android.content.Intent
import android.speech.RecognizerIntent
import java.util.Locale

/**
 * Speech-to-text for task entry, via Android's built-in speech recognition UI
 * (`ACTION_RECOGNIZE_SPEECH`) rather than a raw `SpeechRecognizer` — it needs
 * no RECORD_AUDIO permission from this app and gets a system-provided
 * listening UI for free. That intent launches a system activity, so the
 * actual launch + result callback must live in the calling Activity (via
 * `ActivityResultContracts.StartActivityForResult`); this object only builds
 * the intent and extracts the result, so any Activity can wire it up in a
 * couple of lines.
 */
object MicHandler {

    /**
     * Build a free-form speech recognition intent using the device's current
     * locale (so, e.g., a device set to Hindi gets Hindi recognition).
     */
    fun buildRecognizerIntent(context: Context): Intent =
        Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, Locale.getDefault().toString())
            putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, context.packageName)
        }

    /** Extract the top transcript from a finished recognizer activity's result data, or null. */
    fun extractTranscript(data: Intent?): String? =
        data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)?.firstOrNull()
}
