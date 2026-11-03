package com.toby.jarvishud

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.service.voice.VoiceInteractionService
import android.service.voice.VoiceInteractionSession
import android.service.voice.VoiceInteractionSessionService
import android.speech.RecognitionService

/** Registered as the phone's default digital assistant: long-press home / power → JARVIS instead of 小爱. */
class JarvisAssistService : VoiceInteractionService() {
    override fun onReady() { super.onReady(); Prefs.init(this); Memory.prune(this); WakeService.applyMode(this) }
    override fun onLaunchVoiceAssistFromKeyguard() { showSession(Bundle().apply { putBoolean("listen", true) }, VoiceInteractionSession.SHOW_WITH_ASSIST) }
}

class JarvisSessionService : VoiceInteractionSessionService() {
    override fun onNewSession(args: Bundle?): VoiceInteractionSession = JarvisSession(this)
}

/** The session itself is a trampoline: the microphone is only granted to a foreground window on Xiaomi/HyperOS,
 *  so the HUD lives in the transparent AssistActivity instead of the session window. */
class JarvisSession(c: Context) : VoiceInteractionSession(c) {
    override fun onCreate() { super.onCreate(); setUiEnabled(false) }
    override fun onShow(args: Bundle?, showFlags: Int) {
        super.onShow(args, showFlags)
        Prefs.init(context); AI.log(context, "session onShow flags=$showFlags")
        val i = Intent(context, AssistActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP).putExtra("listen", true)
        args?.getString("query")?.let { i.putExtra("query", it) }
        try { startAssistantActivity(i) } catch (e: Exception) { AI.log(context, "startAssistantActivity: $e"); try { context.startActivity(i) } catch (e2: Exception) { AI.log(context, "startActivity: $e2") } }
        hide()
    }
    override fun onHandleAssist(state: AssistState) { /* we don't read screen content */ }
}

/** Required by the voice-interaction XML; we use the system recognizer instead, so this just declines. */
class JarvisRecognitionService : RecognitionService() {
    override fun onStartListening(i: Intent?, cb: Callback) { try { cb.error(android.speech.SpeechRecognizer.ERROR_RECOGNIZER_BUSY) } catch (_: Exception) {} }
    override fun onCancel(cb: Callback) {}
    override fun onStopListening(cb: Callback) {}
}
