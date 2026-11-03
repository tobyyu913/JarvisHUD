package com.toby.jarvishud

import android.app.*
import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/** Always-on wake word "Jarvis" (foreground service). Mode auto = while charging, on, off. Everything heard goes to Memory. */
class WakeService : Service() {
    companion object {
        const val CH = "jarvis_listen"
        var running = false
        fun shouldListen(c: Context) = when (Prefs.voiceMode) { "on" -> true; "off" -> false; else -> Stats.charging(c) }
        fun applyMode(c: Context) {
            Prefs.init(c)
            val want = shouldListen(c) && ContextCompat.checkSelfPermission(c, android.Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
            if (want && !running) ContextCompat.startForegroundService(c, Intent(c, WakeService::class.java))
            else if (!want && running) c.stopService(Intent(c, WakeService::class.java))
            ChargeJob.schedule(c)
        }
    }
    private val main = Handler(Looper.getMainLooper())
    private var lastWake = 0L
    private val power = object : BroadcastReceiver() { override fun onReceive(c: Context, i: Intent) { main.postDelayed({ applyMode(c) }, 1500) } }

    override fun onBind(i: Intent?): IBinder? = null
    override fun onCreate() {
        super.onCreate(); Prefs.init(this); running = true
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) nm.createNotificationChannel(NotificationChannel(CH, "JARVIS listening", NotificationManager.IMPORTANCE_LOW))
        val n = NotificationCompat.Builder(this, CH).setSmallIcon(R.drawable.ic_launcher_fg).setContentTitle("JARVIS is listening").setContentText("Say \"Jarvis\" followed by your question.").setOngoing(true)
            .setContentIntent(PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)).build()
        if (Build.VERSION.SDK_INT >= 29) startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE) else startForeground(1, n)
        registerReceiver(power, IntentFilter().apply { addAction(Intent.ACTION_POWER_CONNECTED); addAction(Intent.ACTION_POWER_DISCONNECTED) })
        main.post { startRec() }
    }
    override fun onStartCommand(i: Intent?, f: Int, id: Int): Int = START_STICKY
    override fun onDestroy() { running = false; try { unregisterReceiver(power) } catch (_: Exception) {}; session?.stop(); session = null; super.onDestroy() }

    private var session: VoskEngine.Session? = null
    private var errors = 0
    private fun startRec() {
        if (!running) return
        session?.stop()
        val sess = VoskEngine.Session(this,
            onPartial = { },
            onFinal = { t -> errors = 0; Memory.log(this, t); checkWake(t, true) },
            onError = { e -> AI.log(this, "wake: $e"); errors++; if (errors < 20) main.postDelayed({ startRec() }, 3000L * errors) })
        session = sess; sess.start()
    }

    private fun checkWake(text: String, final: Boolean) {
        val lower = text.lowercase()
        val wakes = listOf("jarvis", "jervis", "travis")
        val w = wakes.firstOrNull { lower.contains(it) } ?: return
        if (!final) return
        if (System.currentTimeMillis() - lastWake < 3000) return
        lastWake = System.currentTimeMillis()
        val q = lower.substringAfter(w).trim(' ', ',', '.', '?', '!')
        startActivity(Intent(this, AssistActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("query", q.takeIf { it.split(" ").size >= 2 }).putExtra("listen", q.split(" ").size < 2))
    }
}

/** Fires when the phone starts charging, so automatic mode can start listening without the app being open. */
class ChargeJob : JobService() {
    companion object {
        fun schedule(c: Context) {
            val js = c.getSystemService(JobScheduler::class.java)
            try { js.schedule(JobInfo.Builder(7, ComponentName(c, ChargeJob::class.java)).setRequiresCharging(true).setPersisted(true).build()) } catch (e: Exception) { AI.log(c, "job: $e") }
        }
    }
    override fun onStartJob(p: JobParameters): Boolean { WakeService.applyMode(this); return false }
    override fun onStopJob(p: JobParameters) = false
}
