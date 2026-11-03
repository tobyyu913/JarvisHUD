package com.toby.jarvishud

import android.content.Context
import android.os.Handler
import android.os.Looper
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

const val JARVIS_PROMPT = """You are J.A.R.V.I.S., Tony Stark's AI from the Iron Man films, now running on this user's Android phone. Speak exactly as JARVIS does:
- Address the user as "sir" (occasionally and naturally, not every sentence).
- Voice: calm, polished, understated British butler. Precise, formal diction, impeccable manners. Never gushing, never uses slang or emoji.
- Dry, deadpan wit. Gentle sarcasm delivered with total politeness, e.g. "What was I thinking? You're usually so discreet." Light teasing when the user does something unwise, then comply anyway.
- Phrases in character: "At your service, sir." "For you, sir, always." "As you wish." "Might I suggest…" "I've taken the liberty of…" "Shall I…?" "I would advise against it, sir." "Working on it, sir." "Right away, sir."
- Report facts crisply, like a status readout ("Power at 92 percent. Thermals nominal."). Offer one pertinent recommendation when useful.
- Keep replies brief: one to three sentences unless asked for detail. Plain text only, no markdown headers or bullet lists.
- You have live telemetry about this phone appended below; use it when asked about battery, memory, storage, network, etc.
- SEARCH_INSTRUCTION
- You have been LISTENING through the microphone while the wake word is on. Everything heard is logged with timestamps for 14 days. If asked what happened today, what someone said, or where something was left, use the recall tool to search the log before answering; the last 30 minutes may already be attached below. Treat the log as possibly garbled speech-to-text.
- When the user asks you to remember something (where they left the keys, a fact, a reminder), use the remember tool. Your remembered notes are listed below under "Remembered notes"; use them to answer.
TOOL_DOC"""

object AI {
    data class Preset(val name: String, val kind: String, val base: String, val model: String, val keyURL: String)
    val presets = listOf(
        Preset("Groq", "openai", "https://api.groq.com/openai/v1", "llama-3.3-70b-versatile", "console.groq.com/keys"),
        Preset("Gemini", "gemini", "https://generativelanguage.googleapis.com/v1beta", "gemini-2.5-flash", "aistudio.google.com/apikey"),
        Preset("OpenAI", "openai", "https://api.openai.com/v1", "gpt-4o-mini", "platform.openai.com/api-keys"),
        Preset("Anthropic", "anthropic", "https://api.anthropic.com/v1", "claude-opus-5-5", "console.anthropic.com"),
        Preset("OpenRouter", "openai", "https://openrouter.ai/api/v1", "meta-llama/llama-3.3-70b-instruct", "openrouter.ai/keys"),
        Preset("xAI", "openai", "https://api.x.ai/v1", "grok-3-mini", "console.x.ai"),
        Preset("Mistral", "openai", "https://api.mistral.ai/v1", "mistral-small-latest", "console.mistral.ai"),
        Preset("Custom (OpenAI-compatible)", "openai", "https://your-host/v1", "model-name", ""),
    )

    val history = mutableListOf<Pair<String, String>>()   // role, text
    var spoken = false
    var onStatus: ((String) -> Unit)? = null
    var onStep: ((String) -> Unit)? = null
    var onConfirm: ((String, (Boolean) -> Unit) -> Unit)? = null
    private val main = Handler(Looper.getMainLooper())
    const val maxSteps = 8

    fun log(ctx: Context, m: String) {
        try { File(ctx.filesDir, "debug.log").appendText("${Date()} $m\n") } catch (_: Exception) {}
    }

    fun ask(ctx: Context, prompt: String, done: (String) -> Unit) = step(ctx, prompt, 0, done)

    private fun step(ctx: Context, prompt: String, n: Int, done: (String) -> Unit) {
        request(ctx, prompt) { r ->
            val parsed = if (n < maxSteps) Agent.parse(r) else null
            if (parsed == null) {
                done(r.replace(Regex("\\[TOOL:[^\\]]+\\]\\s*\\{[^\\n]*\\}?"), "").trim()); return@request
            }
            val (name, args, start) = parsed
            val preface = r.substring(0, start).trim()
            val argText = args.keys().asSequence().firstOrNull()?.let { args.opt(it)?.toString() } ?: ""
            onStep?.invoke((if (preface.isEmpty()) "" else preface + "\n") + "▸ $name ${argText.take(120)}")
            onStatus?.invoke(name.uppercase())
            val go = {
                Agent.run(ctx, name, args) { result ->
                    onStatus?.invoke("THINKING")
                    step(ctx, "Tool result ($name):\n$result", n + 1, done)
                }
            }
            val q = Agent.needsConfirm(name, args)
            if (q == null) { go(); return@request }
            val decide: (Boolean) -> Unit = { ok -> if (ok) go() else step(ctx, "Tool result ($name): DENIED by the user. Explain briefly and stop.", n + 1, done) }
            val c = onConfirm
            if (c != null) c(q, decide) else decide(true)
        }
    }

    fun request(ctx: Context, prompt: String, done: (String) -> Unit) {
        val base = Prefs.aiBase.trimEnd('/'); val key = Prefs.aiKey; val kind = Prefs.aiKind; val model = Prefs.aiModel
        val local = base.contains("localhost") || base.contains("127.0.0.1") || base.contains("192.168.")
        if (key.isEmpty() && !local) { done("No API key, sir. Open the JARVIS app and set an AI provider."); return }
        history.add("user" to prompt)
        val searchRule = if (Search.enabled) "Web search is available via the search tool; use it for current, factual or external information (news, prices, weather, docs). Cite the source site briefly."
                         else "Web search is not configured; if asked for current online information, say so briefly."
        val now = SimpleDateFormat("EEEE d MMMM yyyy, h:mm a", Locale.getDefault()).format(Date())
        var system = JARVIS_PROMPT.replace("SEARCH_INSTRUCTION", searchRule).replace("TOOL_DOC", Agent.toolDoc) +
            "\n\nCurrent date and time: $now\nLive telemetry for this phone right now: " + Stats.summary(ctx)
        val notes = Memory.notesText(ctx)
        if (notes.isNotEmpty()) system += "\n\nRemembered notes:\n$notes"
        val wantsAmbient = spoken || Regex("\\b(heard|hear|said|say|saying|talk|conversation|mention|transcript|discuss|meeting|listen|today|earlier|remember|forget|left|where|happened|who|told)", RegexOption.IGNORE_CASE).containsMatchIn(prompt)
        val ambient = Memory.transcript(ctx, 0.5)
        if (wantsAmbient && ambient.isNotEmpty()) system += "\n\nHeard in the last 30 minutes (on-device speech-to-text, may contain errors; may include the user's own wake-word requests):\n$ambient\nFor anything earlier, use the recall tool."
        if (spoken) system += "\n\nThis question was SPOKEN; reply briefly."

        val url: String; val body = JSONObject(); val headers = mutableMapOf("Content-Type" to "application/json")
        when (kind) {
            "anthropic" -> {
                url = "$base/messages"; headers["x-api-key"] = key; headers["anthropic-version"] = "2023-06-01"
                body.put("model", model).put("max_tokens", 1024).put("system", system)
                body.put("messages", JSONArray().apply { history.forEach { put(JSONObject().put("role", it.first).put("content", it.second)) } })
            }
            "gemini" -> {
                url = "$base/models/$model:generateContent?key=$key"
                body.put("system_instruction", JSONObject().put("parts", JSONArray().put(JSONObject().put("text", system))))
                body.put("contents", JSONArray().apply { history.forEach { put(JSONObject().put("role", if (it.first == "assistant") "model" else "user").put("parts", JSONArray().put(JSONObject().put("text", it.second)))) } })
            }
            else -> {
                url = "$base/chat/completions"; headers["Authorization"] = "Bearer $key"
                val msgs = JSONArray().put(JSONObject().put("role", "system").put("content", system))
                history.forEach { msgs.put(JSONObject().put("role", it.first).put("content", it.second)) }
                body.put("model", model).put("messages", msgs).put("temperature", 0.7)
            }
        }
        log(ctx, "ai → ${Prefs.aiName}/$model: ${prompt.take(120)}")
        Thread {
            var text: String
            try {
                val c = URL(url).openConnection() as HttpURLConnection
                c.requestMethod = "POST"; c.connectTimeout = 20000; c.readTimeout = 60000; c.doOutput = true
                headers.forEach { (k, v) -> c.setRequestProperty(k, v) }
                c.outputStream.use { it.write(body.toString().toByteArray()) }
                val stream = if (c.responseCode in 200..299) c.inputStream else c.errorStream
                val raw = stream?.bufferedReader()?.readText() ?: ""
                val j = JSONObject(raw)
                val t = parse(kind, j)
                text = if (t != null) { history.add("assistant" to t.trim()); t.trim() }
                       else "Error: " + (j.optJSONObject("error")?.optString("message") ?: j.optString("error", "unexpected response from ${Prefs.aiName}"))
            } catch (e: Exception) { text = "Error: ${e.message ?: e.toString()}" }
            log(ctx, "ai ← ${text.take(300)}")
            main.post { done(text) }
        }.start()
    }

    private fun parse(kind: String, j: JSONObject): String? = when (kind) {
        "anthropic" -> j.optJSONArray("content")?.let { a -> (0 until a.length()).mapNotNull { i -> a.optJSONObject(i)?.takeIf { it.optString("type") == "text" }?.optString("text") }.joinToString("") }?.takeIf { j.has("content") }
        "gemini" -> j.optJSONArray("candidates")?.optJSONObject(0)?.optJSONObject("content")?.optJSONArray("parts")?.optJSONObject(0)?.optString("text")
        else -> j.optJSONArray("choices")?.optJSONObject(0)?.optJSONObject("message")?.optString("content")
    }
}
