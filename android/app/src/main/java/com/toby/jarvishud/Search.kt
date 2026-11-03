package com.toby.jarvishud

import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

object Search {
    val providers = listOf("Off", "Tavily", "Brave", "Serper (Google)")
    val enabled get() = Prefs.searchProvider != "Off" && Prefs.searchKey.isNotEmpty()

    /** Blocking; call off the main thread. */
    fun run(q: String): String {
        val key = Prefs.searchKey
        return try {
            val c: HttpURLConnection
            when (Prefs.searchProvider) {
                "Tavily" -> { c = URL("https://api.tavily.com/search").openConnection() as HttpURLConnection; c.requestMethod = "POST"; c.doOutput = true
                    c.setRequestProperty("Content-Type", "application/json")
                    c.outputStream.use { it.write(JSONObject().put("api_key", key).put("query", q).put("max_results", 5).put("include_answer", true).toString().toByteArray()) } }
                "Brave" -> { c = URL("https://api.search.brave.com/res/v1/web/search?count=5&q=" + URLEncoder.encode(q, "UTF-8")).openConnection() as HttpURLConnection
                    c.setRequestProperty("X-Subscription-Token", key); c.setRequestProperty("Accept", "application/json") }
                else -> { c = URL("https://google.serper.dev/search").openConnection() as HttpURLConnection; c.requestMethod = "POST"; c.doOutput = true
                    c.setRequestProperty("X-API-KEY", key); c.setRequestProperty("Content-Type", "application/json")
                    c.outputStream.use { it.write(JSONObject().put("q", q).put("num", 5).toString().toByteArray()) } }
            }
            c.connectTimeout = 15000; c.readTimeout = 20000
            val j = JSONObject((if (c.responseCode in 200..299) c.inputStream else c.errorStream).bufferedReader().readText())
            val lines = mutableListOf<String>()
            j.optString("answer").takeIf { it.isNotEmpty() }?.let { lines += "Summary: $it" }
            val items = j.optJSONArray("results") ?: j.optJSONObject("web")?.optJSONArray("results") ?: j.optJSONArray("organic")
            if (items != null) for (i in 0 until minOf(5, items.length())) {
                val r = items.getJSONObject(i)
                val u = r.optString("url").ifEmpty { r.optString("link") }
                val b = r.optString("content").ifEmpty { r.optString("description").ifEmpty { r.optString("snippet") } }
                lines += "- ${r.optString("title")} ($u): ${b.take(400)}"
            }
            (j.optJSONObject("error")?.optString("message") ?: j.optString("error").takeIf { it.isNotEmpty() })?.let { lines += "Error: $it" }
            if (lines.isEmpty()) "No results." else lines.joinToString("\n")
        } catch (e: Exception) { "Search failed: ${e.message}" }
    }
}
