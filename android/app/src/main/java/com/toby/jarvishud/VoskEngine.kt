package com.toby.jarvishud

import android.content.Context
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import org.json.JSONObject
import org.vosk.Model
import org.vosk.Recognizer
import org.vosk.android.StorageService

/** Offline, on-device speech recognition (Vosk). Works without Google services, which Xiaomi phones often lack for third-party apps. */
object VoskEngine {
    @Volatile private var model: Model? = null
    @Volatile private var loading = false
    private val waiters = mutableListOf<(Model?) -> Unit>()
    private val main = Handler(Looper.getMainLooper())

    fun load(c: Context, done: (Model?) -> Unit) {
        model?.let { done(it); return }
        synchronized(waiters) { waiters += done; if (loading) return; loading = true }
        StorageService.unpack(c.applicationContext, "model-en-us", "model", { m ->
            model = m; loading = false
            val w = synchronized(waiters) { val l = waiters.toList(); waiters.clear(); l }
            main.post { w.forEach { it(m) } }
        }, { e ->
            AI.log(c, "vosk load failed: $e"); loading = false
            val w = synchronized(waiters) { val l = waiters.toList(); waiters.clear(); l }
            main.post { w.forEach { it(null) } }
        })
    }

    /** A microphone session: partial/final text callbacks on the main thread. */
    class Session(private val c: Context, private val onPartial: (String) -> Unit, private val onFinal: (String) -> Unit, private val onError: (String) -> Unit) {
        @Volatile private var running = false
        private var thread: Thread? = null
        private var lastPartial = ""

        fun start() {
            load(c) { m ->
                if (m == null) { onError("offline speech model failed to load"); return@load }
                if (running) return@load
                running = true
                thread = Thread({ loop(m) }, "vosk-mic").also { it.start() }
            }
        }
        fun stop() { running = false; thread = null }

        private fun loop(m: Model) {
            val rate = 16000
            val min = AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
            // Right after the HUD is summoned (power / home key) the window may not yet count as foreground, and
            // HyperOS only hands the mic to foreground windows, so retry for a couple of seconds before giving up.
            var rec: AudioRecord? = null
            for (attempt in 0 until 6) {
                if (!running) return
                val r = try { AudioRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION, rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, maxOf(min, 8192) * 2) } catch (e: Exception) { null }
                if (r != null && r.state == AudioRecord.STATE_INITIALIZED) { rec = r; break }
                try { r?.release() } catch (_: Exception) {}
                Thread.sleep(350)
            }
            if (rec == null) { main.post { onError("microphone not available") }; running = false; return }
            val recognizer = Recognizer(m, rate.toFloat())
            val buf = ShortArray(4096)
            try {
                rec.startRecording()
                while (running) {
                    val n = rec.read(buf, 0, buf.size)
                    if (n < 0) { main.post { onError("microphone read error $n") }; break }
                    if (recognizer.acceptWaveForm(buf, n)) {
                        val t = JSONObject(recognizer.result).optString("text").trim()
                        lastPartial = ""
                        if (t.isNotEmpty()) main.post { onFinal(t) }
                    } else {
                        val p = JSONObject(recognizer.partialResult).optString("partial").trim()
                        if (p.isNotEmpty() && p != lastPartial) { lastPartial = p; main.post { onPartial(p) } }
                    }
                }
                val t = JSONObject(recognizer.finalResult).optString("text").trim()
                if (t.isNotEmpty() && running.not()) main.post { onFinal(t) }
            } catch (e: Exception) { main.post { onError("speech: $e") } }
            finally { try { rec.stop() } catch (_: Exception) {}; rec.release(); recognizer.close(); running = false }
        }
    }
}
