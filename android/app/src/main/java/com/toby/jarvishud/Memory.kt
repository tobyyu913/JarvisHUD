package com.toby.jarvishud

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Persistent memory: all-day heard log (14 days) + remembered notes, in the app's private files. */
object Memory {
    private const val keepDays = 14
    private val day = SimpleDateFormat("yyyy-MM-dd", Locale.US)
    private val stamp = SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.US)
    private fun dir(c: Context) = File(c.filesDir, "heard").apply { mkdirs() }
    private fun file(c: Context, d: Date) = File(dir(c), day.format(d) + ".log")

    @Synchronized fun log(c: Context, text: String) {
        val t = text.trim(); if (t.isEmpty()) return
        file(c, Date()).appendText("[${stamp.format(Date())}] $t\n")
    }

    fun transcript(c: Context, hours: Double, maxChars: Int = 4000): String {
        val cutoff = System.currentTimeMillis() - (hours * 3600_000).toLong()
        val out = mutableListOf<String>()
        for (d in 0..(hours / 24).toInt() + 1) {
            val f = file(c, Date(System.currentTimeMillis() - d * 86400_000L)); if (!f.exists()) continue
            f.forEachLine { l -> if (l.length > 18) { val t = try { stamp.parse(l.substring(1, 17))?.time } catch (_: Exception) { null }; if (t != null && t >= cutoff) out += l } }
        }
        out.sort()
        var s = out.joinToString("\n"); if (s.length > maxChars) s = "…" + s.takeLast(maxChars); return s
    }

    fun search(c: Context, query: String, maxLines: Int = 40): String {
        val words = query.lowercase().split(" ").filter { it.length > 2 }
        if (words.isEmpty()) return transcript(c, 24.0)
        val hits = mutableListOf<String>()
        for (f in (dir(c).listFiles() ?: emptyArray()).sortedByDescending { it.name }) {
            for (l in f.readLines().reversed()) if (words.any { l.lowercase().contains(it) }) { hits += l; if (hits.size >= maxLines) return hits.reversed().joinToString("\n") }
        }
        return if (hits.isEmpty()) "(nothing heard matching: $query)" else hits.reversed().joinToString("\n")
    }

    fun forgetToday(c: Context) { file(c, Date()).delete() }
    fun forgetAllHeard(c: Context) { dir(c).listFiles()?.forEach { it.delete() } }
    fun prune(c: Context) { val cut = day.format(Date(System.currentTimeMillis() - keepDays * 86400_000L)); dir(c).listFiles()?.filter { it.nameWithoutExtension < cut }?.forEach { it.delete() } }

    private fun notesFile(c: Context) = File(c.filesDir, "notes.json")
    fun notes(c: Context): JSONArray = try { JSONArray(notesFile(c).readText()) } catch (_: Exception) { JSONArray() }
    private fun save(c: Context, a: JSONArray) = notesFile(c).writeText(a.toString(2))
    fun remember(c: Context, note: String): String { val a = notes(c); a.put(JSONObject().put("when", stamp.format(Date())).put("note", note.trim())); save(c, a); return "Noted (${a.length()} notes kept)." }
    fun forgetNote(c: Context, text: String): String {
        val a = notes(c); val keep = JSONArray(); var removed = 0
        for (i in 0 until a.length()) { val o = a.getJSONObject(i); if (o.optString("note").lowercase().contains(text.lowercase())) removed++ else keep.put(o) }
        save(c, keep); return if (removed == 0) "No note matched \"$text\"." else "Forgot $removed note(s)."
    }
    fun forgetAllNotes(c: Context) { save(c, JSONArray()) }
    fun notesText(c: Context): String { val a = notes(c); return (0 until a.length()).joinToString("\n") { val o = a.getJSONObject(it); "[${o.optString("when")}] ${o.optString("note")}" } }
}
