package com.toby.jarvishud

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.os.Build
import android.os.Environment
import android.os.StatFs
import android.os.SystemClock
import java.io.File

object Stats {
    fun charging(c: Context): Boolean {
        val i = c.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED)) ?: return false
        val s = i.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
        return s == BatteryManager.BATTERY_STATUS_CHARGING || s == BatteryManager.BATTERY_STATUS_FULL || i.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) != 0
    }

    fun summary(c: Context): String {
        val b = c.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val level = b?.let { it.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) * 100 / it.getIntExtra(BatteryManager.EXTRA_SCALE, 100) } ?: -1
        val temp = (b?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, 0) ?: 0) / 10.0
        val plugged = when (b?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0)) { BatteryManager.BATTERY_PLUGGED_AC -> "AC"; BatteryManager.BATTERY_PLUGGED_USB -> "USB"; BatteryManager.BATTERY_PLUGGED_WIRELESS -> "wireless"; else -> "unplugged" }
        val am = c.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val mi = ActivityManager.MemoryInfo().also { am.getMemoryInfo(it) }
        val st = StatFs(Environment.getDataDirectory().path)
        val caps = try { val cm = c.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager; cm.getNetworkCapabilities(cm.activeNetwork) } catch (_: Exception) { null }
        val net = when { caps == null -> "offline"; caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "Wi-Fi"; caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"; else -> "other" }
        val cpuMax = try { File("/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq").readText().trim().toLong() / 1000 } catch (_: Exception) { 0L }
        val cpuCur = try { File("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq").readText().trim().toLong() / 1000 } catch (_: Exception) { 0L }
        val up = SystemClock.elapsedRealtime() / 1000
        return "${Build.MANUFACTURER} ${Build.MODEL}, Android ${Build.VERSION.RELEASE}. Battery $level% ($plugged, ${temp}°C). " +
            "Memory ${(mi.totalMem - mi.availMem) / 1048576} / ${mi.totalMem / 1048576} MB used${if (mi.lowMemory) " (LOW)" else ""}. " +
            "Storage ${st.availableBytes / 1073741824} GB free of ${st.totalBytes / 1073741824} GB. Network: $net. " +
            "CPU0 ${cpuCur}/${cpuMax} MHz, ${Runtime.getRuntime().availableProcessors()} cores. Uptime ${up / 3600}h ${(up % 3600) / 60}m."
    }
}
