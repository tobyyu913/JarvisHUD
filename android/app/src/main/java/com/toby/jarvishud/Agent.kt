package com.toby.jarvishud

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.AlarmClock
import org.json.JSONObject

object Agent {
    val toolDoc = """
You are an AGENT on this phone: you can act, not just talk. To use a tool, output a line in exactly this form (one tool per reply, nothing else on that line):
[TOOL:name]{"arg": "value"}
After the tool runs you receive its result and continue. Chain several steps if needed, then give the final answer in plain prose with no tag. Tools:
- open_app {"name": "Spotify"}  launch an installed app by name.
- open_url {"url": "https://..."}  open a web page, or any URI (tel:, mailto:, geo:, spotify:).
- search {"query": "..."}  web search (only if enabled).
- telemetry {}  fresh battery/memory/storage/network snapshot of this phone.
- alarm {"hour": 7, "minute": 30, "label": "..."}  set an alarm. timer {"seconds": 600, "label": "..."}  start a timer.
- reminder {"text": "...", "hour": 18, "minute": 30}  create a reminder/alarm for a deadline today (use the current date and time given below).
- clipboard {"text": "..."} put text on the clipboard; {} reads it.
- recall {"query": "keys"} search everything heard (last 14 days) for words; {"hours": 8} returns everything heard in the last N hours instead.
- remember {"note": "keys are in the kitchen drawer"} store a note permanently.
- forget {"note": "keys"} delete remembered notes containing the text.
Rules: be decisive, act first, then report briefly. Never ask permission in text. Never fabricate a tool result.
""".trimIndent()

    private val main = Handler(Looper.getMainLooper())

    fun run(ctx: Context, name: String, args: JSONObject, done: (String) -> Unit) {
        Thread {
            val r: String = try {
                when (name) {
                    "open_app" -> openApp(ctx, args.optString("name"))
                    "open_url" -> { val u = args.optString("url"); ctx.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(u)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); "opened $u" }
                    "search" -> if (Search.enabled) Search.run(args.optString("query")) else "search is not configured"
                    "telemetry" -> Stats.summary(ctx)
                    "alarm" -> { ctx.startActivity(Intent(AlarmClock.ACTION_SET_ALARM).putExtra(AlarmClock.EXTRA_HOUR, args.optInt("hour")).putExtra(AlarmClock.EXTRA_MINUTES, args.optInt("minute")).putExtra(AlarmClock.EXTRA_MESSAGE, args.optString("label", "JARVIS")).putExtra(AlarmClock.EXTRA_SKIP_UI, true).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); "alarm set for ${args.optInt("hour")}:${"%02d".format(args.optInt("minute"))}" }
                    "timer" -> { ctx.startActivity(Intent(AlarmClock.ACTION_SET_TIMER).putExtra(AlarmClock.EXTRA_LENGTH, args.optInt("seconds")).putExtra(AlarmClock.EXTRA_MESSAGE, args.optString("label", "JARVIS")).putExtra(AlarmClock.EXTRA_SKIP_UI, true).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); "timer started for ${args.optInt("seconds")} s" }
                    "reminder" -> { ctx.startActivity(Intent(AlarmClock.ACTION_SET_ALARM).putExtra(AlarmClock.EXTRA_HOUR, args.optInt("hour")).putExtra(AlarmClock.EXTRA_MINUTES, args.optInt("minute")).putExtra(AlarmClock.EXTRA_MESSAGE, args.optString("text", "Reminder")).putExtra(AlarmClock.EXTRA_SKIP_UI, true).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); Memory.remember(ctx, "Reminder: ${args.optString("text")} at ${args.optInt("hour")}:${"%02d".format(args.optInt("minute"))}"); "reminder alarm set for ${args.optInt("hour")}:${"%02d".format(args.optInt("minute"))} and noted" }
                    "clipboard" -> { val cm = ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                        if (args.has("text")) { main.post { cm.setPrimaryClip(ClipData.newPlainText("JARVIS", args.optString("text"))) }; "copied" }
                        else { val t = cm.primaryClip?.getItemAt(0)?.coerceToText(ctx)?.toString() ?: ""; if (t.isEmpty()) "(clipboard empty)" else t } }
                    "recall" -> if (args.has("hours")) Memory.transcript(ctx, args.optDouble("hours", 8.0)).ifEmpty { "(nothing heard in the last ${args.optDouble("hours")} hours)" } else Memory.search(ctx, args.optString("query"))
                    "remember" -> Memory.remember(ctx, args.optString("note"))
                    "forget" -> Memory.forgetNote(ctx, args.optString("note"))
                    else -> "unknown tool $name"
                }
            } catch (e: Exception) { "failed: ${e.message}" }
            main.post { done(r) }
        }.start()
    }

    private fun openApp(ctx: Context, name: String): String {
        val pm = ctx.packageManager
        val apps = pm.queryIntentActivities(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER), 0)
        val n = name.lowercase()
        val hit = apps.firstOrNull { it.loadLabel(pm).toString().lowercase() == n } ?: apps.firstOrNull { it.loadLabel(pm).toString().lowercase().contains(n) || it.activityInfo.packageName.lowercase().contains(n.replace(" ", "")) }
            ?: return "no app named $name. Installed: " + apps.map { it.loadLabel(pm).toString() }.sorted().joinToString(", ").take(1500)
        val i = pm.getLaunchIntentForPackage(hit.activityInfo.packageName) ?: return "cannot launch $name"
        ctx.startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); return "launched ${hit.loadLabel(pm)}"
    }

    fun needsConfirm(name: String, args: JSONObject): String? {
        if (!Prefs.agentConfirm) return null
        return when (name) {
            "open_url" -> args.optString("url").let { if (it.startsWith("http")) null else "Open $it?" }
            else -> null
        }
    }

    /** Returns (name, args, startIndex) for "[TOOL:name]{json}" or null. */
    fun parse(r: String): Triple<String, JSONObject, Int>? {
        val m = Regex("\\[TOOL:([a-z_]+)\\]").find(r) ?: return null
        var rest = r.substring(m.range.last + 1).trim()
        if (rest.startsWith("```")) rest = rest.replace(Regex("^```\\w*\\n?"), "")
        var depth = 0; var end = -1; var inStr = false; var esc = false
        for (i in rest.indices) {
            val ch = rest[i]
            if (inStr) { if (esc) esc = false else if (ch == '\\') esc = true else if (ch == '"') inStr = false; continue }
            if (ch == '"') inStr = true else if (ch == '{') depth++ else if (ch == '}') { depth--; if (depth == 0) { end = i; break } }
        }
        val st = rest.indexOf('{')
        val args = if (end >= 0 && st >= 0) try { JSONObject(rest.substring(st, end + 1)) } catch (_: Exception) { JSONObject() } else JSONObject()
        return Triple(m.groupValues[1], args, m.range.first)
    }
}
