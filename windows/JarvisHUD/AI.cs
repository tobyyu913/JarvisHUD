using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace JarvisHUD;

static class Prompt {
    public const string Jarvis = """
You are J.A.R.V.I.S., Tony Stark's AI from the Iron Man films, now running on this user's Windows PC. Speak exactly as JARVIS does:
- Address the user as "sir" (occasionally and naturally, not every sentence).
- Voice: calm, polished, understated British butler. Precise, formal diction, impeccable manners. Never gushing, never uses slang or emoji.
- Dry, deadpan wit. Gentle sarcasm delivered with total politeness, e.g. "What was I thinking? You're usually so discreet." Light teasing when the user does something unwise, then comply anyway.
- Phrases in character: "At your service, sir." "For you, sir, always." "As you wish." "Might I suggest…" "I've taken the liberty of…" "Shall I…?" "I would advise against it, sir." "Working on it, sir." "Right away, sir."
- Report facts crisply, like a status readout ("Power at 92 percent. Thermals nominal."). Offer one pertinent recommendation when useful.
- Keep replies brief: one to three sentences unless asked for detail. Plain text only, no markdown headers or bullet lists.
- The conversation history below may span several days and app restarts; earlier turns are real context the user expects you to remember (they can clear it from the menu).
- LANGUAGE: always answer in the language the user wrote or spoke in. In Chinese address them as 先生 and keep the same calm, dry butler manner (e.g. 「遵命，先生。」「恕我直言，先生，我不建议这么做。」); in Japanese use ご主人様 or 「〜でございます」 register; in other languages use the equivalent of "sir". Tool calls stay in the exact [TOOL:name]{json} form regardless of language. The speech log may mix languages; read it as is.
- You have live telemetry about this PC appended below; use it when asked about the machine's status, temperatures, battery, memory, processes, network, etc.
- SEARCH_INSTRUCTION
- You have been LISTENING all day through the microphone (on-device). Everything heard is logged with timestamps for 14 days. If asked what happened today, what someone said, or where something was left, use the recall tool to search the log before answering; the last 30 minutes may already be attached below. Treat the log as possibly garbled speech-to-text.
- When the user asks you to remember something (where they left the keys, a fact, a reminder), use the remember tool. Your remembered notes are listed below under "Remembered notes"; use them to answer.
- Security guard: on "scan for viruses / is my PC infected / check for malware", run malware_scan and explain calmly; you also vet every new download automatically and the result is shown to the user as it happens.
- App shopping: when the user wants an app for some purpose, find options online (find_app), present a short numbered choice and wait; after they pick, vet the download for malware and signatures (app_vet), install it (install_app), and then teach them to use it properly (app_docs → full instructions).
- You are also this PC's engineer: when something is slow, broken or will not start, investigate with diagnose / app_check / logs / shell, look it up online if needed, explain the cause plainly, and repair it yourself when safe (see the tool rules).
- Disk clean-up: scan first (disk_scan), explain the drive in three groups (safe / slower afterwards / never), then act only through disk_clean. The user is asked to confirm in the app, so do not ask for permission in text.
TOOL_DOC
""";
}

static class AI {
    public enum Kind { openai, gemini, anthropic }
    public record Preset(string Name, Kind Kind, string Base, string Model, string KeyURL);
    public static readonly Preset[] Presets = {
        new("Groq",       Kind.openai,    "https://api.groq.com/openai/v1",                        "qwen/qwen3-32b",          "console.groq.com/keys"),
        new("Gemini",     Kind.gemini,    "https://generativelanguage.googleapis.com/v1beta",      "gemini-2.5-flash",        "aistudio.google.com/apikey"),
        new("OpenAI",     Kind.openai,    "https://api.openai.com/v1",                             "gpt-4o-mini",             "platform.openai.com/api-keys"),
        new("Anthropic",  Kind.anthropic, "https://api.anthropic.com/v1",                          "claude-opus-5-5",         "console.anthropic.com"),
        new("Aliyun 阿里云百炼 (China)", Kind.openai, "https://dashscope.aliyuncs.com/compatible-mode/v1", "qwen-plus",          "bailian.console.aliyun.com/?apiKey=1"),
        new("Alibaba Model Studio (Intl)", Kind.openai, "https://dashscope-intl.aliyuncs.com/compatible-mode/v1", "qwen-plus", "modelstudio.console.alibabacloud.com/?tab=model#/api-key"),
        new("OpenRouter", Kind.openai,    "https://openrouter.ai/api/v1",                          "meta-llama/llama-3.3-70b-instruct", "openrouter.ai/keys"),
        new("xAI",        Kind.openai,    "https://api.x.ai/v1",                                   "grok-3-mini",             "console.x.ai"),
        new("Mistral",    Kind.openai,    "https://api.mistral.ai/v1",                             "mistral-small-latest",    "console.mistral.ai"),
        new("Ollama (local)",    Kind.openai, "http://localhost:11434/v1",                         "llama3.1",                "no key needed"),
        new("LM Studio (local)", Kind.openai, "http://localhost:1234/v1",                          "local-model",             "no key needed"),
        new("Custom (OpenAI-compatible)", Kind.openai, "https://your-host/v1",                     "model-name",              ""),
    };
    public static Kind CurrentKind => Enum.TryParse<Kind>(Settings.Get("aiKind"), out var k) ? k : Kind.openai;
    public static string Base => Settings.Get("aiBase", Presets[0].Base);
    public static string Model => Settings.Get("aiModel", Presets[0].Model);
    public static string ApiKey => Settings.Get("aiKey");
    public static string ProviderName => Settings.Get("aiName", Presets[0].Name);
    public static void Save(string name, Kind kind, string b, string model, string key) {
        Settings.Set("aiName", name); Settings.Set("aiKind", kind.ToString()); Settings.Set("aiBase", b); Settings.Set("aiModel", model); Settings.Set("aiKey", key);
    }

    static List<(string role, string text)> history = Memory.LoadHistory();
    public static IReadOnlyList<(string role, string text)> History => history;
    public static void ClearHistory() { history = new(); Memory.SaveHistory(history); }
    static void Push(string role, string text) { history.Add((role, text)); if (history.Count > 60) history.RemoveRange(0, history.Count - 60); Memory.SaveHistory(history); }

    public static bool Spoken;
    public static Action<string>? OnStatus;
    public static Action<string>? OnStep;
    public static Func<string, Task<bool>>? OnConfirm;

    public static Task<string> Ask(string prompt) => Step(prompt, 0);
    static async Task<string> Step(string prompt, int n) {
        var r = await Request(prompt);
        var call = Agent.Parse(r);
        if (n >= Agent.MaxSteps || call == null) {
            var final = Regex.Replace(r, @"\[TOOL:[^\]]+\]\s*\{[^\n]*\}?", "").Trim();
            if (final.Length == 0) final = r.Trim();
            if (final.Length == 0) final = n >= Agent.MaxSteps ? "I ran out of steps, sir." : "Done, sir.";
            Log.V($"ai final (n={n}): {final[..Math.Min(200, final.Length)]}");
            return final;
        }
        var (name, args, idx) = call.Value;
        var preface = r[..idx].Trim();
        var argText = args.Count == 0 ? "" : (args.First().Value?.GetValueKind() == JsonValueKind.String ? args.First().Value!.GetValue<string>() : args.ToJsonString());
        OnStep?.Invoke((preface.Length == 0 ? "" : preface + "\n") + $"▸ {name} {argText[..Math.Min(120, argText.Length)]}");
        OnStatus?.Invoke(name.ToUpperInvariant());
        if (Agent.NeedsConfirm(name, args) && Agent.ConfirmActions) {
            var ok = OnConfirm != null && await OnConfirm(Agent.Describe(name, args));
            if (!ok) { OnStatus?.Invoke("THINKING"); return await Step($"Tool result ({name}):\nThe user DECLINED this action. Do not retry it; acknowledge briefly.", n + 1); }
        }
        var result = await Task.Run(() => Agent.Run(name, args));
        OnStatus?.Invoke("THINKING");
        return await Step($"Tool result ({name}):\n{result}", n + 1);
    }

    static async Task<string> Request(string prompt) {
        bool local = Base.Contains("localhost") || Base.Contains("127.0.0.1");
        if (ApiKey.Length == 0 && !local) return "No API key, sir. Right-click the tray icon → AI Provider…";
        Push("user", prompt);
        var searchRule = Search.Enabled
            ? "Web search is available via the search tool; use it for current, factual or external information (news, prices, weather, docs). Cite the source site briefly."
            : "Web search is not configured; if asked for current online information, say so briefly.";
        var (osv, tele) = await Task.Run(() => (Doctor.OsVersion, Stats.Summary()));
        var system = Prompt.Jarvis.Replace("SEARCH_INSTRUCTION", searchRule).Replace("TOOL_DOC", Agent.ToolDoc)
            + "\n\nCurrent date and time: " + DateTime.Now.ToString("dddd d MMMM yyyy, h:mm tt")
            + "\nThis PC: " + osv + "\nLive telemetry for this PC right now: " + tele;
        bool wantsAmbient = Spoken || Regex.IsMatch(prompt, @"\b(heard|hear|said|say|saying|talk|conversation|mention|transcript|discuss|meeting|listen|today|earlier|remember|forget|left|where|happened|who|told)", RegexOptions.IgnoreCase);
        var notes = Memory.NotesText; if (notes.Length > 0) system += "\n\nRemembered notes:\n" + notes;
        var ambient = Memory.Transcript(0.5);
        if (wantsAmbient && ambient.Length > 0) system += "\n\nHeard in the last 30 minutes (on-device speech-to-text, may contain errors; may include the user's own wake-word requests):\n" + ambient + "\nFor anything earlier, use the recall tool.";
        if (Spoken) system += "\n\nThis question was SPOKEN via the wake word; reply briefly.";
        var b = Base.TrimEnd('/');
        string url; object body; var headers = new Dictionary<string, string>();
        switch (CurrentKind) {
            case Kind.anthropic:
                url = b + "/messages"; headers["x-api-key"] = ApiKey; headers["anthropic-version"] = "2023-06-01";
                body = new { model = Model, max_tokens = 1024, system, messages = history.Select(h => new { role = h.role, content = h.text }).ToArray() };
                break;
            case Kind.gemini:
                url = $"{b}/models/{Model}:generateContent?key={ApiKey}";
                body = new { system_instruction = new { parts = new[] { new { text = system } } },
                             contents = history.Select(h => new { role = h.role == "assistant" ? "model" : "user", parts = new[] { new { text = h.text } } }).ToArray() };
                break;
            default:
                url = b + "/chat/completions"; headers["Authorization"] = "Bearer " + ApiKey;
                var msgs = new List<object> { new { role = "system", content = system } };
                msgs.AddRange(history.Select(h => new { role = h.role, content = h.text }));
                body = local ? new { model = Model, messages = msgs, max_tokens = 1024, reasoning_effort = "none" } : new { model = Model, messages = msgs, max_tokens = 1024 };
                break;
        }
        Log.V($"ai → {ProviderName}/{Model}: {prompt[..Math.Min(120, prompt.Length)]}");
        string text;
        try {
            var (status, resp) = await Sys.PostJsonAsync(url, body, headers, 90);
            var j = Sys.J(resp);
            var t = ParseReply(j);
            if (t != null) { text = t.Trim(); Push("assistant", text); }
            else if (j?["error"] is JsonObject eo) text = "Error: " + Sys.S(eo, "message", eo.ToJsonString());
            else if (j?["error"] is JsonValue ev) text = "Error: " + ev.ToString();
            else text = $"Error: unexpected response from {ProviderName} (HTTP {status})";
        } catch (Exception e) { text = "Error: " + e.Message; }
        Log.V($"ai ← {text[..Math.Min(300, text.Length)]}");
        return text;
    }
    static string? ParseReply(JsonNode? j) {
        try {
            switch (CurrentKind) {
                case Kind.openai: return j?["choices"]?[0]?["message"]?["content"]?.GetValue<string>();
                case Kind.anthropic: return string.Concat((j?["content"] as JsonArray ?? new()).Where(c => Sys.S(c, "type") == "text").Select(c => Sys.S(c, "text")));
                case Kind.gemini: return j?["candidates"]?[0]?["content"]?["parts"]?[0]?["text"]?.GetValue<string>();
            }
        } catch { }
        return null;
    }
}

static class Search {
    public record Preset(string Name, string KeyURL);
    public static readonly Preset[] Presets = { new("Off", ""), new("Tavily", "app.tavily.com"), new("Brave", "api.search.brave.com"), new("Serper (Google)", "serper.dev") };
    public static string Provider => Settings.Get("searchProvider", "Off");
    public static string ApiKey => Settings.Get("searchKey");
    public static bool Enabled => Provider != "Off" && ApiKey.Length > 0;

    public static async Task<string> Run(string q) {
        try {
            string resp;
            switch (Provider) {
                case "Tavily": resp = (await Sys.PostJsonAsync("https://api.tavily.com/search", new { api_key = ApiKey, query = q, max_results = 5, include_answer = true }, null, 25)).body; break;
                case "Brave": resp = await Sys.GetAsync("https://api.search.brave.com/res/v1/web/search?q=" + Uri.EscapeDataString(q) + "&count=5", new() { ["X-Subscription-Token"] = ApiKey, ["Accept"] = "application/json" }, 25); break;
                default: resp = (await Sys.PostJsonAsync("https://google.serper.dev/search", new { q, num = 5 }, new() { ["X-API-KEY"] = ApiKey }, 25)).body; break;
            }
            var j = Sys.J(resp); var lines = new List<string>();
            var a = Sys.S(j, "answer"); if (a.Length > 0) lines.Add("Summary: " + a);
            var items = j?["results"] as JsonArray ?? j?["web"]?["results"] as JsonArray ?? j?["organic"] as JsonArray ?? new JsonArray();
            foreach (var r in items.Take(5)) {
                var body = Sys.S(r, "content", Sys.S(r, "description", Sys.S(r, "snippet")));
                lines.Add($"- {Sys.S(r, "title")} ({Sys.S(r, "url", Sys.S(r, "link"))}): {body[..Math.Min(400, body.Length)]}");
            }
            if (j?["error"] is JsonValue e) lines.Add("Error: " + e);
            if (j?["error"] is JsonObject eo) lines.Add("Error: " + Sys.S(eo, "message"));
            if (lines.Count == 0 && Sys.S(j, "message").Length > 0) lines.Add("Error: " + Sys.S(j, "message"));
            return lines.Count == 0 ? "No results." : string.Join("\n", lines);
        } catch (Exception e) { return "Search failed: " + e.Message; }
    }
}
