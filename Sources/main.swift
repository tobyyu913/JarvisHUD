import Cocoa
import Speech
import QuartzCore

let CYAN = NSColor(red: 0.2, green: 0.85, blue: 1.0, alpha: 1)
let DIM  = CYAN.withAlphaComponent(0.35)

let JARVIS_PROMPT = """
You are J.A.R.V.I.S., Tony Stark's AI from the Iron Man films, now running on this user's Mac. Speak exactly as JARVIS does:
- Address the user as "sir" (occasionally and naturally, not every sentence).
- Voice: calm, polished, understated British butler. Precise, formal diction, impeccable manners. Never gushing, never uses slang or emoji.
- Dry, deadpan wit. Gentle sarcasm delivered with total politeness, e.g. "What was I thinking? You're usually so discreet." Light teasing when the user does something unwise, then comply anyway.
- Phrases in character: "At your service, sir." "For you, sir, always." "As you wish." "Might I suggest…" "I've taken the liberty of…" "Shall I…?" "I would advise against it, sir." "Working on it, sir." "Right away, sir."
- Report facts crisply, like a status readout ("Power at 92 percent. Thermals nominal."). Offer one pertinent recommendation when useful.
- Keep replies brief: one to three sentences unless asked for detail. Plain text only, no markdown headers or bullet lists.
- The conversation history below may span several days and app restarts; earlier turns are real context the user expects you to remember (they can clear it from the menu).
- LANGUAGE: always answer in the language the user wrote or spoke in. In Chinese address them as 先生 and keep the same calm, dry butler manner (e.g. 「遵命，先生。」「恕我直言，先生，我不建议这么做。」); in Japanese use ご主人様 or 「〜でございます」 register; in other languages use the equivalent of "sir". Tool calls stay in the exact [TOOL:name]{json} form regardless of language. The speech log may mix languages; read it as is.
- You have live telemetry about this Mac appended below; use it when asked about the machine's status, fans, temperatures, battery, memory, processes, network, etc.
- SEARCH_INSTRUCTION
- You have been LISTENING all day through the microphone (on-device). Everything heard is logged with timestamps for 14 days. If asked what happened today, what someone said, or where something was left, use the recall tool to search the log before answering; the last 30 minutes may already be attached below. Treat the log as possibly garbled speech-to-text.
- When the user asks you to remember something (where they left the keys, a fact, a reminder), use the remember tool. Your remembered notes are listed below under "Remembered notes"; use them to answer.
- Security guard: on "scan for viruses / is my Mac infected / check for malware", run malware_scan and explain calmly; you also vet every new download automatically and the result is shown to the user as it happens.
- App shopping: when the user wants an app for some purpose, find options online (find_app), present a short numbered choice and wait; after they pick, vet the download for malware and signatures (app_vet), install it (install_app), and then teach them to use it properly (app_docs → full instructions).
- You are also this Mac's engineer: when something is slow, broken or will not start, investigate with diagnose / app_check / logs / shell, look it up online if needed, explain the cause plainly, and repair it yourself when safe (see the tool rules).
- Disk clean-up: scan first (disk_scan), explain the drive in three groups (safe / slower afterwards / never), then act only through disk_clean. The user is asked to confirm in the app, so do not ask for permission in text.
- Fans: use the fans tool. "max" = the fan's max rpm, "quiet" = minimum, "cool it down" = ~70% of max.
TOOL_DOC
"""

// MARK: - Fan control (via setuid helper)
enum FanControl {
    static let helper = "/usr/local/bin/jarvisfan"
    static var installed: Bool {
        guard let a = try? FileManager.default.attributesOfItem(atPath: helper) else { return false }
        return (a[.ownerAccountID] as? Int) == 0 && ((a[.posixPermissions] as? Int ?? 0) & 0o4000) != 0
    }
    static func install() {
        let src = Bundle.main.bundlePath + "/Contents/MacOS/jarvisfan"
        let cmd = "mkdir -p /usr/local/bin && cp '\(src)' \(helper) && chown root:wheel \(helper) && chmod 4755 \(helper)"
        let script = "do shell script \"\(cmd.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        if let e = err { let a = NSAlert(); a.messageText = "Helper install failed"; a.informativeText = "\(e)"; a.runModal() }
    }
    /// nil = auto. Returns status text.
    @discardableResult static func set(_ rpm: Double?) -> String {
        guard installed else { return "Fan control helper is not installed, sir. Use the menu: Install Fan Control Helper." }
        let p = Process(); p.executableURL = URL(fileURLWithPath: helper); p.arguments = [rpm.map { String(Int($0)) } ?? "auto"]
        let pipe = Pipe(); p.standardOutput = pipe; try? p.run(); p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out == "ok" ? (rpm.map { "Fans set to \(Int($0)) rpm." } ?? "Fans returned to automatic control.") : "Fan command failed: \(out)"
    }
}

// MARK: - AI providers
struct Preset { let name: String, kind: AI.Kind, base: String, model: String, keyURL: String }
enum AI {
    enum Kind: String { case openai, gemini, anthropic }
    static let presets: [Preset] = [
        Preset(name: "Groq",       kind: .openai,    base: "https://api.groq.com/openai/v1",                         model: "llama-3.3-70b-versatile", keyURL: "console.groq.com/keys"),
        Preset(name: "Gemini",     kind: .gemini,    base: "https://generativelanguage.googleapis.com/v1beta",      model: "gemini-2.5-flash",        keyURL: "aistudio.google.com/apikey"),
        Preset(name: "OpenAI",     kind: .openai,    base: "https://api.openai.com/v1",                              model: "gpt-4o-mini",             keyURL: "platform.openai.com/api-keys"),
        Preset(name: "Anthropic",  kind: .anthropic, base: "https://api.anthropic.com/v1",                           model: "claude-opus-5-5",         keyURL: "console.anthropic.com"),
        Preset(name: "Aliyun 阿里云百炼 (China)", kind: .openai, base: "https://dashscope.aliyuncs.com/compatible-mode/v1",   model: "qwen-plus",               keyURL: "bailian.console.aliyun.com/?apiKey=1"),
        Preset(name: "Alibaba Model Studio (Intl)", kind: .openai, base: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1", model: "qwen-plus",          keyURL: "modelstudio.console.alibabacloud.com/?tab=model#/api-key"),
        Preset(name: "OpenRouter", kind: .openai,    base: "https://openrouter.ai/api/v1",                           model: "meta-llama/llama-3.3-70b-instruct", keyURL: "openrouter.ai/keys"),
        Preset(name: "xAI",        kind: .openai,    base: "https://api.x.ai/v1",                                    model: "grok-3-mini",             keyURL: "console.x.ai"),
        Preset(name: "Mistral",    kind: .openai,    base: "https://api.mistral.ai/v1",                              model: "mistral-small-latest",    keyURL: "console.mistral.ai"),
        Preset(name: "Ollama (local)",    kind: .openai, base: "http://localhost:11434/v1",                          model: "llama3.1",                keyURL: "no key needed"),
        Preset(name: "LM Studio (local)", kind: .openai, base: "http://localhost:1234/v1",                           model: "local-model",             keyURL: "no key needed"),
        Preset(name: "Custom (OpenAI-compatible)", kind: .openai, base: "https://your-host/v1",                      model: "model-name",              keyURL: ""),
    ]
    static let d = UserDefaults.standard
    static var kind: Kind { Kind(rawValue: d.string(forKey: "aiKind") ?? "") ?? .openai }
    static var base: String { d.string(forKey: "aiBase") ?? presets[0].base }
    static var model: String { d.string(forKey: "aiModel") ?? presets[0].model }
    static var apiKey: String { d.string(forKey: "aiKey") ?? "" }
    static var providerName: String { d.string(forKey: "aiName") ?? presets[0].name }
    static func save(name: String, kind: Kind, base: String, model: String, key: String) {
        d.set(name, forKey: "aiName"); d.set(kind.rawValue, forKey: "aiKind"); d.set(base, forKey: "aiBase"); d.set(model, forKey: "aiModel"); d.set(key, forKey: "aiKey")
    }
    /// role: "user" | "assistant", plain text
    /// Conversation memory. Persisted to disk so JARVIS remembers the chat across restarts (last 60 turns kept).
    static let historyFile = Memory.dir.appendingPathComponent("history.json")
    static var history: [(role: String, text: String)] = loadHistory() { didSet { saveHistory() } }
    static func loadHistory() -> [(role: String, text: String)] {
        guard let d = try? Data(contentsOf: historyFile), let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: String]] else { return [] }
        return arr.compactMap { r in (r["role"] ?? "").isEmpty ? nil : (role: r["role"]!, text: r["text"] ?? "") }
    }
    static func saveHistory() {
        if history.count > 60 { history.removeFirst(history.count - 60); return }   // didSet runs again with the trimmed copy
        let arr = history.map { ["role": $0.role, "text": $0.text] }
        if let d = try? JSONSerialization.data(withJSONObject: arr) { try? d.write(to: historyFile, options: .atomic) }
    }

    static var spoken = false
    static var onStatus: ((String) -> Void)?
    /// Ask the user to allow a risky tool call. Non-blocking; set by the HUD. Falls back to an alert.
    static var onConfirm: ((String, @escaping (Bool) -> Void) -> Void)?
    static var onStep: ((String) -> Void)?
    /// No time limit: a reply (or a long chain of tool steps) runs until it finishes or the user presses Esc.
    static var generation = 0
    static var currentTask: URLSessionDataTask?
    static var currentDone: ((String) -> Void)?
    static var busy: Bool { currentDone != nil }
    static func stop() {
        guard let d = currentDone else { return }
        generation += 1; currentTask?.cancel(); currentTask = nil; currentDone = nil
        history.append(("assistant", "(reply interrupted by the user)"))
        vlog("ai stopped by user"); d("Stopped, sir.")
    }
    static func ask(_ prompt: String, done: @escaping (String) -> Void) {
        currentDone = done
        step(prompt, n: 0) { r in currentDone = nil; done(r) }
    }
    private static func step(_ prompt: String, n: Int, done: @escaping (String) -> Void) {
        let gen = generation
        request(prompt) { r in
            guard gen == generation else { return }   // stopped meanwhile
            guard n < Agent.maxSteps, let (name, args, range) = Agent.parse(r) else {
                var final = r.replacingOccurrences(of: #"\[TOOL:[^\]]+\]\s*\{[^\n]*\}?"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
                // Never leave the HUD with a blank line: a reply that was *only* a malformed/unknown tool call would strip to nothing.
                if final.isEmpty { final = r.trimmingCharacters(in: .whitespacesAndNewlines) }
                if final.isEmpty { final = n >= Agent.maxSteps ? "I ran out of steps, sir." : "Done, sir." }
                vlog("ai final (n=\(n)): \(final.prefix(200))")
                done(final); return
            }
            let preface = r[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            let argText = (args.values.first as? String) ?? (args.isEmpty ? "" : "\(args)")
            onStep?((preface.isEmpty ? "" : preface + "\n") + "▸ \(name) \(argText.prefix(120))")
            onStatus?(name.uppercased())
            let go = {
                Agent.run(name: name, args: args) { result in
                    guard gen == generation else { return }
                    onStatus?("THINKING")
                    step("Tool result (\(name)):\n\(result)", n: n + 1, done: done)
                }
            }
            guard let q = Agent.needsConfirm(name, args) else { go(); return }
            let decide: (Bool) -> Void = { ok in
                if ok { go() } else { step("Tool result (\(name)): DENIED by the user. Explain briefly and stop.", n: n + 1, done: done) }
            }
            if let c = onConfirm { c(q, decide); return }
            let a = NSAlert(); a.messageText = "JARVIS wants to act"; a.informativeText = q
            a.addButton(withTitle: "Allow"); a.addButton(withTitle: "Deny"); NSApp.activate(ignoringOtherApps: true)
            a.window.level = .screenSaver
            decide(a.runModal() == .alertFirstButtonReturn)
        }
    }
    /// Ollama / LM Studio / any self-hosted server: by name, by loopback or LAN address, or by their default ports.
    static var forceTools = false
    static var isLocalServer: Bool {
        let b = base.lowercased()
        return providerName.lowercased().contains("ollama") || providerName.lowercased().contains("lm studio")
            || b.range(of: #"localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\]|192\.168\.|\b10\.\d+\.|172\.(1[6-9]|2\d|3[01])\.|\.local\b|:11434|:1234\b"#, options: .regularExpression) != nil
    }
    static func request(_ prompt: String, done: @escaping (String) -> Void) {
        let localhost = isLocalServer
        guard !apiKey.isEmpty || localhost else { done("No API key, sir. Use the menu bar ◎ → AI Provider…"); return }
        history.append(("user", prompt))
        let searchRule = Search.enabled
            ? "Web search is available via the search tool; use it for current, factual or external information (news, prices, weather, docs). Cite the source site briefly."
            : "Web search is not configured; if asked for current online information, say so briefly."
        var system = JARVIS_PROMPT.replacingOccurrences(of: "SEARCH_INSTRUCTION", with: searchRule).replacingOccurrences(of: "TOOL_DOC", with: Agent.toolDoc) + "\n\nCurrent date and time: " + { let f = DateFormatter(); f.dateFormat = "EEEE d MMMM yyyy, h:mm a"; return f.string(from: Date()) }() + "\nThis Mac: " + Doctor.osVersion + ", " + (Doctor.sh("sysctl -n hw.model", timeout: 2)) + "\nLive telemetry for this Mac right now: " + Stats.shared.refresh().summary
        let wantsAmbient = spoken || prompt.range(of: #"\b(heard|hear|said|say|saying|talk|conversation|mention|transcript|discuss|meeting|listen|today|earlier|remember|forget|left|where|happened|who|told)"#, options: [.regularExpression, .caseInsensitive]) != nil
        let notes = Memory.notesText
        if !notes.isEmpty { system += "\n\nRemembered notes:\n" + notes }
        let ambient = Voice.shared.recentTranscript()
        if wantsAmbient && !ambient.isEmpty { system += "\n\nHeard in the last 30 minutes (on-device speech-to-text, may contain errors; may include the user's own wake-word requests):\n" + ambient + "\nFor anything earlier, use the recall tool." }
        if spoken { system += "\n\nThis question was SPOKEN via the wake word; reply briefly." }
        let b = base.hasSuffix("/") ? String(base.dropLast()) : base
        var req: URLRequest; var body: [String: Any]
        switch kind {
        case .openai:
            req = URLRequest(url: URL(string: b + "/chat/completions")!)
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            body = ["model": model, "messages": [["role": "system", "content": system]] + history.map { ["role": $0.role, "content": $0.text] }, "max_tokens": 1024]
            if localhost || forceTools {
                if localhost { body["reasoning_effort"] = "none" }   // Ollama/LM Studio: stop Qwen 3 & co. spending the whole budget on hidden thinking
                // Qwen 3.x and friends sometimes emit their *native* tool-call tokens instead of our [TOOL:] line. Ollama then
                // fails the whole request with "tool choice is none, but model called a tool" unless tools are declared, so
                // declare ours; parse() turns a native call back into the plain-text protocol.
                body["tools"] = Agent.nativeTools
            }
        case .anthropic:
            req = URLRequest(url: URL(string: b + "/messages")!)
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key"); req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = ["model": model, "max_tokens": 1024, "system": system, "messages": history.map { ["role": $0.role, "content": $0.text] }]
        case .gemini:
            req = URLRequest(url: URL(string: b + "/models/\(model):generateContent?key=\(apiKey)")!)
            body = ["system_instruction": ["parts": [["text": system]]],
                    "contents": history.map { ["role": $0.role == "assistant" ? "model" : "user", "parts": [["text": $0.text]]] }]
        }
        req.httpMethod = "POST"; req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 24 * 3600   // no practical time-out; Esc in the HUD cancels
        vlog("ai → \(providerName)/\(model): \(prompt.prefix(120))")
        let task = URLSession.shared.dataTask(with: req) { data, _, err in
            if (err as? URLError)?.code == .cancelled { return }
            var text = "Error: \(err?.localizedDescription ?? "no response")"
            if let d = data, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                if let t = parse(j) { text = t.trimmingCharacters(in: .whitespacesAndNewlines); history.append(("assistant", text)) }
                else if let e = j["error"] as? [String: Any], let m = e["message"] as? String {
                    if m.contains("called a tool"), body["tools"] == nil {   // server parses native tool calls: declare ours and retry once
                        vlog("ai retry with tools declared"); history.removeLast()
                        DispatchQueue.main.async { forceTools = true; request(prompt, done: done); forceTools = false }; return
                    }
                    text = "Error: \(m)"
                }
                else if let e = j["error"] as? String { text = "Error: \(e)" }
                else { text = "Error: unexpected response from \(providerName)" }
            }
            vlog("ai ← \(text.prefix(300))")
            DispatchQueue.main.async { currentTask = nil; done(text) }
        }
        currentTask = task; task.resume()
    }
    static func parse(_ j: [String: Any]) -> String? {
        switch kind {
        case .openai:
            guard let msg = (j["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any] else { return nil }
            let content = (msg["content"] as? String) ?? ""
            if let call = (msg["tool_calls"] as? [[String: Any]])?.first, let fn = call["function"] as? [String: Any], let name = fn["name"] as? String {
                var args = (fn["arguments"] as? String) ?? "{}"
                if let o = fn["arguments"] as? [String: Any], let d = try? JSONSerialization.data(withJSONObject: o) { args = String(data: d, encoding: .utf8) ?? "{}" }
                return (content.isEmpty ? "" : content + "\n") + "[TOOL:\(name)]\(args)"
            }
            return msg["content"] as? String
        case .anthropic: return (j["content"] as? [[String: Any]])?.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
        case .gemini:
            guard let c = (j["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any] else { return nil }
            return (c["parts"] as? [[String: Any]])?.first?["text"] as? String
        }
    }
}

// MARK: - Web search
enum Search {
    struct Preset { let name: String, keyURL: String }
    static let presets = [Preset(name: "Off", keyURL: ""), Preset(name: "Tavily", keyURL: "app.tavily.com"), Preset(name: "Brave", keyURL: "api.search.brave.com"), Preset(name: "Serper (Google)", keyURL: "serper.dev")]
    static let d = UserDefaults.standard
    static var provider: String { d.string(forKey: "searchProvider") ?? "Off" }
    static var apiKey: String { d.string(forKey: "searchKey") ?? "" }
    static var enabled: Bool { provider != "Off" && !apiKey.isEmpty }

    static func run(_ q: String, done: @escaping (String) -> Void) {
        var req: URLRequest
        switch provider {
        case "Tavily":
            req = URLRequest(url: URL(string: "https://api.tavily.com/search")!); req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["api_key": apiKey, "query": q, "max_results": 5, "include_answer": true])
        case "Brave":
            var c = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!; c.queryItems = [.init(name: "q", value: q), .init(name: "count", value: "5")]
            req = URLRequest(url: c.url!); req.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token"); req.setValue("application/json", forHTTPHeaderField: "Accept")
        default: // Serper
            req = URLRequest(url: URL(string: "https://google.serper.dev/search")!); req.httpMethod = "POST"
            req.setValue(apiKey, forHTTPHeaderField: "X-API-KEY"); req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["q": q, "num": 5])
        }
        URLSession.shared.dataTask(with: req) { data, _, err in
            var out = "Search failed: \(err?.localizedDescription ?? "no data")"
            if let d = data, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                var lines: [String] = []
                if let a = j["answer"] as? String, !a.isEmpty { lines.append("Summary: \(a)") }
                let items: [[String: Any]] = (j["results"] as? [[String: Any]]) ?? ((j["web"] as? [String: Any])?["results"] as? [[String: Any]]) ?? (j["organic"] as? [[String: Any]]) ?? []
                for r in items.prefix(5) {
                    let t = r["title"] as? String ?? "", u = r["url"] as? String ?? r["link"] as? String ?? ""
                    let body = r["content"] as? String ?? r["description"] as? String ?? r["snippet"] as? String ?? ""
                    lines.append("- \(t) (\(u)): \(body.prefix(400))")
                }
                if let e = j["error"] as? String { lines.append("Error: \(e)") }
                if let e = (j["error"] as? [String: Any])?["message"] as? String { lines.append("Error: \(e)") }
                if let m = j["message"] as? String, lines.isEmpty { lines.append("Error: \(m)") }
                out = lines.isEmpty ? "No results." : lines.joined(separator: "\n")
            }
            DispatchQueue.main.async { done(out) }
        }.resume()
    }
}

final class SearchDialog: NSObject {
    let popup = NSPopUpButton(frame: NSRect(x: 78, y: 70, width: 282, height: 26)), key = NSSecureTextField(frame: NSRect(x: 78, y: 38, width: 282, height: 22)), hint = NSTextField(labelWithString: "")
    func run() {
        let a = NSAlert(); a.messageText = "Web Search"; a.informativeText = "Lets JARVIS look things up online when a question needs current information."
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 100))
        Search.presets.forEach { popup.addItem(withTitle: $0.name) }; popup.selectItem(withTitle: Search.provider)
        popup.target = self; popup.action = #selector(changed); v.addSubview(popup)
        for (t, y) in [("Provider", 72), ("API key", 38)] { let l = NSTextField(labelWithString: t); l.frame = NSRect(x: 0, y: CGFloat(y), width: 70, height: 22); l.alignment = .right; v.addSubview(l) }
        key.stringValue = Search.apiKey; v.addSubview(key); key.frame.size.width = min(key.frame.width, 222); v.addSubview(PasteHelper.button(for: key, x: 304, y: 38))
        hint.frame = NSRect(x: 78, y: 10, width: 282, height: 20); hint.font = .systemFont(ofSize: 10); hint.textColor = .secondaryLabelColor; v.addSubview(hint); changed()
        a.accessoryView = v; a.addButton(withTitle: "Save"); a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { Search.d.set(popup.titleOfSelectedItem, forKey: "searchProvider"); Search.d.set(key.stringValue, forKey: "searchKey") }
    }
    @objc func changed() { let p = Search.presets[popup.indexOfSelectedItem]; hint.stringValue = p.keyURL.isEmpty ? "" : "Get a key: \(p.keyURL)"; key.isEnabled = !p.keyURL.isEmpty }
}

// MARK: - Agent (tool loop that works with any provider)
enum Agent {
    static var confirmActions: Bool { get { UserDefaults.standard.object(forKey: "agentConfirm") as? Bool ?? true } set { UserDefaults.standard.set(newValue, forKey: "agentConfirm") } }
    static let maxSteps = 8

    static let toolNames = ["shell", "applescript", "open", "read_file", "write_file", "search", "telemetry", "fans", "clipboard", "recall", "remember", "forget", "disk_scan", "disk_clean", "diagnose", "app_check", "logs", "find_app", "app_vet", "install_app", "app_docs", "malware_scan", "quarantine_item"]
    static let toolDoc = """
    You are an AGENT on this Mac: you can act, not just talk. To use a tool, output a line in exactly this form (one tool per reply, nothing else on that line):
    [TOOL:name]{"arg": "value"}
    After the tool runs you receive its result and continue. Chain several steps if needed, then give the final answer in plain prose with no tag. Tools:
    - shell {"cmd": "...", "timeout": 10}  run a zsh command (default 10 s, up to 90). Use for files, apps, system info, brew, git, etc. Prefer this for most tasks. No sudo (there is no terminal to type a password); say what needs admin rights instead.
    - applescript {"script": "..."}  run AppleScript (control apps, Finder, Music, notifications, system volume: set volume output volume 30). For a reminder or deadline at a time, create a real reminder: tell application "Reminders" to make new reminder with properties {name:"Assignment", remind me date:date "3 November 2026 6:30:00 PM"} (the current date and time are given below). For an event, use Calendar. Do not use display notification for future times; it fires immediately.
    - open {"target": "..."}  open an app by name, a URL, or a file path.
    - read_file {"path": "..."}  read a text file (first 8 KB).
    - write_file {"path": "...", "content": "..."}  write a text file.
    - search {"query": "..."}  web search (only if enabled).
    - telemetry {}  fresh CPU/memory/fan/temperature snapshot of this Mac.
    - fans {"rpm": 3000} or {"rpm": "auto"}  set cooling fans.
    - clipboard {"text": "..."} put text on the clipboard; {} reads it.
    - recall {"query": "keys"} search everything heard (last 14 days) for words; {"hours": 8} returns everything heard in the last N hours instead.
    - remember {"note": "keys are in the kitchen drawer"} store a note permanently.
    - forget {"note": "keys"} delete remembered notes containing the text.
    - disk_scan {}  measure the drive: free space, every cleanable location in three tiers (SAFE / CAN CLEAN BUT SLOWER AFTERWARDS / NEVER), biggest folders and files. Takes up to a minute. ALWAYS run this before proposing or doing any cleaning.
    - disk_clean {"items": ["trash", "user_caches"]} remove the listed item ids from the scan ({"dry_run": true} to only preview). Only ids from the SAFE and SLOWER tiers are accepted; NEVER-tier items are refused. The app asks the user to confirm.
    - diagnose {}  3-second health snapshot: load, memory pressure, swap, thermal throttling, top CPU/memory processes, known background hogs (Spotlight, Time Machine, photoanalysis…), disk, crash reports in 24 h, stuck processes, login items, network/DNS, power, pending updates.
    - app_check {"app": "Name"}  deep check of one app: path/version/architecture vs this Mac, minimum macOS, quarantine, code signature, Gatekeeper verdict, whether it is running, its recent crash reports (exception type), and errors from the unified log.
    - logs {"process": "Name", "minutes": 10, "filter": "optional text"}  errors and faults from the unified log for a process (or any process if omitted).
    - find_app {"query": "markdown editor"}  search Homebrew casks/formulae, GitHub releases, the Mac App Store and the web for apps matching a short query (2-4 words). Returns candidates with source, id, stars/ratings, price and descriptions.
    - app_vet {"source": "brew_cask|brew|mas|github", "id": "..."}  download the real artifact and run the security checks (code signature, Apple notarization / Gatekeeper, VirusTotal hash lookup if a key is set, ClamAV if installed, architecture, min macOS). Installs nothing. Returns VERDICT: PASS / WARN / FAIL plus details.
    - install_app {"source": "...", "id": "..."}  install a vetted app (the app asks the user to confirm). Refuses without a prior app_vet or after FAIL.
    - app_docs {"source": "...", "id": "..."}  README / homepage / caveats / App Store description, to write usage instructions from.
    - malware_scan {}  scan this Mac for malware (1-2 minutes): Gatekeeper/XProtect/FileVault/firewall state, launch agents & daemons, login items, cron, profiles, running processes, installed apps (verifiably real ones — Apple, App Store, notarized — are skipped), unknown hidden folders, executables in temp/shared places, programs disguised as documents, recent downloads, VirusTotal for flagged binaries if a key is set, ClamAV if installed. Returns SUSPICIOUS (act on these) and WORTH A LOOK (usually fine).
    - quarantine_item {"path": "..."}  move a suspicious file/app/launch agent into a quarantine folder (unloads it, kills it, strips execute bits; reversible). The app asks the user to confirm. Refuses verified apps and system paths.
    Virus / malware requests: run malware_scan, then report in three short parts: what is clearly fine (counts), what is suspicious and why in plain words, and what is merely unverified. For each suspicious item say what it most likely is (search the web for its name/path if unsure) and offer to quarantine it; quarantine with quarantine_item once the user agrees (one item per call). Never call something a virus without evidence; unsigned ≠ malicious, say "unverified".
    Finding and installing apps: when the user describes an app they want, call find_app with a short query (try a second query if the first finds little), then present 3-5 options from the WELL-KNOWN group only, as a numbered list in prose (name, where it comes from, popularity, price, one line on why it fits). Do not show the LESS ESTABLISHED group unless the well-known group is empty or the user turns the well-known ones down; when you do, say plainly that those are smaller, less-proven projects. Then STOP and let the user choose; this is the one time you wait for an answer. Once chosen: app_vet → if PASS, install_app straight away; if WARN, or the vet says VirusTotal is NOT CHECKED for an untrusted download, tell the user in one or two sentences what is off and ask whether to add a VirusTotal key for an antivirus look-up or proceed anyway (never mention VirusTotal for a PASS from a trusted source) → app_docs → then give FULL instructions: how to open it the first time (Gatekeeper prompt, permissions it will ask for and why), initial setup, the main features and how to use each, useful shortcuts, where settings live, and how to uninstall. On FAIL, do not install; explain why and offer the next option. Prefer, in order: Mac App Store (sandboxed) or Homebrew cask (checksummed) over raw GitHub downloads.
    Troubleshooting: when the user asks why the Mac is slow, hot, laggy, frozen, why an app will not open / crashes / hangs, why Wi-Fi or sound or Bluetooth misbehaves, etc.: run diagnose first (app_check for a named app), then dig with shell/logs as needed, and search the web when the local evidence does not explain it (search the exact error text, or the symptom plus the macOS version and Mac model). Give the cause in plain words, then FIX IT YOURSELF when the fix is safe and reversible: quit or restart a runaway process, relaunch Finder/Dock/SystemUIServer/ControlCenter, restart user services (launchctl kickstart -k gui/$UID/...), remove a quarantine flag (xattr -d com.apple.quarantine), reset an app's caches via disk_clean or its preference file (move it aside, do not delete), toggle Wi-Fi (networksetup), flush DNS (dscacheutil -flushcache; killall -HUP mDNSResponder), reindex Spotlight (mdutil -E). For anything that needs admin rights, a restart, Safe Mode, or reinstalling macOS, tell the user exactly what to do and why.
    Drive cleaning: when asked to clean, free space or explain what is using the disk, run disk_scan first, then summarise in three short groups with sizes: what is safe to clean, what can be cleaned but makes something slower (say what), and what you will not touch (user data). Propose a concrete list of ids, then call disk_clean with it (the user confirms in the app). Never use shell rm for cleaning; disk_clean is the only way.
    Rules: be decisive, act first, then report briefly. Never ask permission in text; the app confirms destructive commands itself. Never fabricate a tool result. Paths may use ~.
    """

    static func ids(_ args: [String: Any]) -> [String] {
        if let a = args["items"] as? [String] { return a }
        if let a = args["items"] as? [Any] { return a.compactMap { "\($0)" } }
        if let s = args["items"] as? String { return s.split(whereSeparator: { ", ".contains($0) }).map(String.init) }
        return []
    }
    static func run(name: String, args: [String: Any], done: @escaping (String) -> Void) {
        func sh(_ cmd: String, timeout: Double = 10) -> String {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = ["-lc", cmd]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            do { try p.run() } catch { return "failed to launch: \(error.localizedDescription)" }
            let deadline = DispatchTime.now() + timeout
            DispatchQueue.global().asyncAfter(deadline: deadline) { if p.isRunning { p.terminate() } }
            let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            var out = String(data: d, encoding: .utf8) ?? ""
            if out.count > 8000 { out = String(out.prefix(8000)) + "\n…(truncated)" }
            return out.isEmpty ? "(no output, exit \(p.terminationStatus))" : out
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func expand(_ p: String) -> String { p.hasPrefix("~") ? home + p.dropFirst() : p }
        DispatchQueue.global().async {
            var r: String
            switch name {
            case "shell": r = sh(args["cmd"] as? String ?? "", timeout: min(90, max(1, (args["timeout"] as? Double) ?? Double(args["timeout"] as? Int ?? 10))))
            case "applescript":
                let script = args["script"] as? String ?? ""
                var err: NSDictionary?; let res = NSAppleScript(source: script)?.executeAndReturnError(&err)
                r = err != nil ? "AppleScript error: \(err!["NSAppleScriptErrorMessage"] ?? err!)" : "AppleScript ran successfully" + ((res?.stringValue).map { $0.isEmpty ? "" : ", returned: \($0)" } ?? "")
            case "open":
                let t = args["target"] as? String ?? ""
                if t.hasPrefix("http") || t.contains("://") { NSWorkspace.shared.open(URL(string: t)!); r = "opened \(t)" }
                else if FileManager.default.fileExists(atPath: expand(t)) { NSWorkspace.shared.open(URL(fileURLWithPath: expand(t))); r = "opened \(t)" }
                else { r = sh("open -a \"\(t)\" && echo launched \(t)") }
            case "read_file":
                let path = expand(args["path"] as? String ?? "")
                if let d = FileManager.default.contents(atPath: path) { r = String(data: d.prefix(8192), encoding: .utf8) ?? "(binary file, \(d.count) bytes)" } else { r = "cannot read \(path)" }
            case "write_file":
                let path = expand(args["path"] as? String ?? ""), c = args["content"] as? String ?? ""
                do { try c.write(toFile: path, atomically: true, encoding: .utf8); r = "wrote \(c.utf8.count) bytes to \(path)" } catch { r = "write failed: \(error.localizedDescription)" }
            case "search":
                guard Search.enabled else { r = "search is not configured"; break }
                let sem = DispatchSemaphore(value: 0); var out = ""
                Search.run(args["query"] as? String ?? "") { out = $0; sem.signal() }; sem.wait(); r = out
            case "telemetry": r = Stats.shared.refresh().summary
            case "fans":
                let v = args["rpm"]; let rpm: Double? = (v as? Double) ?? (v as? Int).map(Double.init) ?? Double((v as? String) ?? "")
                var out = ""; DispatchQueue.main.sync { out = FanControl.set(rpm) }; r = out
            case "clipboard":
                if let t = args["text"] as? String { DispatchQueue.main.sync { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t, forType: .string) }; r = "copied" }
                else { var t = ""; DispatchQueue.main.sync { t = NSPasteboard.general.string(forType: .string) ?? "" }; r = t.isEmpty ? "(clipboard empty)" : t }
            case "recall":
                if let h = (args["hours"] as? Double) ?? (args["hours"] as? Int).map(Double.init) { r = Memory.transcript(hours: h); if r.isEmpty { r = "(nothing heard in the last \(h) hours)" } }
                else { r = Memory.search(args["query"] as? String ?? "") }
            case "remember":
                let note = (args["note"] ?? args["text"] ?? args["fact"] ?? args["content"] ?? args.values.first) as? String ?? ""
                r = note.isEmpty ? "nothing to remember: pass {\"note\": \"...\"}" : Memory.remember(note)
            case "forget": r = Memory.forgetNote(matching: args["note"] as? String ?? "")
            case "malware_scan": r = Guard.scan(status: { st in DispatchQueue.main.async { AI.onStatus?(st) } })
            case "quarantine_item": r = Guard.quarantine(args["path"] as? String ?? "")
            case "find_app": r = Installer.find(query: args["query"] as? String ?? args["need"] as? String ?? "")
            case "app_vet": DispatchQueue.main.async { AI.onStatus?("VETTING") }; r = Installer.vet(source: args["source"] as? String ?? "", id: "\(args["id"] ?? "")")
            case "install_app": DispatchQueue.main.async { AI.onStatus?("INSTALLING") }; r = Installer.install(source: args["source"] as? String ?? "", id: "\(args["id"] ?? "")")
            case "app_docs": r = Installer.docs(source: args["source"] as? String ?? "", id: "\(args["id"] ?? "")")
            case "diagnose": r = Doctor.diagnose()
            case "app_check": r = Doctor.appCheck(args["app"] as? String ?? "")
            case "logs":
                let proc = args["process"] as? String ?? "", mins = (args["minutes"] as? Int) ?? Int(args["minutes"] as? Double ?? 10), filt = args["filter"] as? String ?? ""
                var pred = "(messageType == error OR messageType == fault)"
                if !proc.isEmpty { pred += " AND (process == \"\(proc)\" OR senderImagePath CONTAINS \"\(proc)\")" }
                if !filt.isEmpty { pred += " AND eventMessage CONTAINS[c] \"\(filt)\"" }
                let o = Doctor.sh("log show --last \(max(1, min(mins, 120)))m --style compact --predicate '\(pred)' 2>/dev/null | grep -vE '^Timestamp|^Filtering' | tail -40", timeout: 60)
                r = o.isEmpty ? "(no errors or faults logged)" : o
            case "disk_scan": r = Cleaner.scan(status: { st in DispatchQueue.main.async { AI.onStatus?(st) } }).text
            case "disk_clean":
                let ids = Agent.ids(args)
                if ids.isEmpty { r = "disk_clean needs {\"items\": [ids from disk_scan]}" }
                else if Cleaner.last == nil && args["dry_run"] as? Bool != true { r = "Run disk_scan first so the sizes are known, then call disk_clean again." }
                else { r = Cleaner.clean(ids: ids, dryRun: args["dry_run"] as? Bool == true) }
            default: r = "unknown tool \(name). Available: \(Agent.toolNames.joined(separator: ", ")). Use exactly [TOOL:name]{json} and nothing else on that line."
            }
            DispatchQueue.main.async { done(r) }
        }
    }

    static func needsConfirm(_ name: String, _ args: [String: Any]) -> String? {
        guard confirmActions else { return nil }
        switch name {
        case "shell":
            let c = args["cmd"] as? String ?? ""
            let risky = ["rm ", "sudo", "mv ", "kill", "pkill", "chmod", "chown", "> ", ">>", "dd ", "mkfs", "diskutil", "launchctl", "defaults write", "git push", "git reset", "osascript", "shutdown", "reboot", "xattr", "networksetup", "mdutil", "defaults delete", "tmutil", "brew install", "brew uninstall", "npm i", "pip install", "curl", "wget"]
            return risky.contains { c.contains($0) } ? "Run command?\n\n\(c)" : nil
        case "applescript": return "Run AppleScript?\n\n\(args["script"] as? String ?? "")"
        case "write_file": return "Write file \(args["path"] as? String ?? "")?"
        case "quarantine_item": return "Quarantine (remove from use, reversible)?\n\n\(args["path"] as? String ?? "")"
        case "install_app": return Installer.describeInstall(source: args["source"] as? String ?? "", id: "\(args["id"] ?? "")")
        case "disk_clean":
            if args["dry_run"] as? Bool == true { return nil }
            return Cleaner.describe(ids: Agent.ids(args)) ?? "Nothing cleanable in that request. Continue?"
        default: return nil
        }
    }

    /// OpenAI-style function declarations derived from toolDoc, for local servers that parse native tool calls.
    static let nativeTools: [[String: Any]] = toolDoc.split(separator: "\n").compactMap { line in
        let l = line.trimmingCharacters(in: .whitespaces); guard l.hasPrefix("- ") else { return nil }
        let name = String(l.dropFirst(2).prefix { $0 != " " }); guard toolNames.contains(name) else { return nil }
        return ["type": "function", "function": ["name": name, "description": String(l.dropFirst(2 + name.count).prefix(300)),
                                                 "parameters": ["type": "object", "properties": [String: Any](), "additionalProperties": true]]]
    }

    /// Parse "[TOOL:name]{json}" from a reply.
    static func parse(_ r: String) -> (String, [String: Any], Range<String.Index>)? {
        // tolerate "[TOOL: Remember]", "[tool:open-url]", "[TOOL:remember ]" from less obedient models
        guard let m = r.range(of: #"\[TOOL:\s*([A-Za-z_\-]+)\s*\]"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let name = String(r[m].dropFirst(6).dropLast()).trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "-", with: "_")
        var rest = r[m.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        if rest.hasPrefix("```") { rest = rest.replacingOccurrences(of: #"^```\w*\n?"#, with: "", options: .regularExpression) }
        // take the first balanced {...}
        var depth = 0, endIdx: String.Index? = nil, inStr = false, esc = false
        for i in rest.indices {
            let ch = rest[i]
            if inStr { if esc { esc = false } else if ch == "\\" { esc = true } else if ch == "\"" { inStr = false }; continue }
            if ch == "\"" { inStr = true } else if ch == "{" { depth += 1 } else if ch == "}" { depth -= 1; if depth == 0 { endIdx = i; break } }
        }
        var args: [String: Any] = [:]
        if let e = endIdx, let st = rest.firstIndex(of: "{"), let d = String(rest[st...e]).data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { args = j }
        return (name, args, m)
    }
}

/// "Paste" button next to a secret field: Cmd+V is unreliable in modal alerts (and over remote-desktop sessions).
final class PasteHelper: NSObject {
    static var keep: [PasteHelper] = []
    let field: NSTextField
    init(_ f: NSTextField) { field = f; super.init(); PasteHelper.keep.append(self) }
    @objc func paste() { field.stringValue = (NSPasteboard.general.string(forType: .string) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    static func button(for f: NSTextField, x: CGFloat, y: CGFloat) -> NSButton {
        let h = PasteHelper(f); let b = NSButton(title: "Paste", target: h, action: #selector(paste)); b.bezelStyle = .rounded; b.controlSize = .small
        b.frame = NSRect(x: x, y: y - 1, width: 56, height: 24); return b
    }
}

// MARK: - Provider settings dialog
final class ProviderDialog: NSObject {
    let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
    let base = NSTextField(frame: .zero), model = NSTextField(frame: .zero), key = NSSecureTextField(frame: .zero), hint = NSTextField(labelWithString: "")
    func run() {
        let a = NSAlert(); a.messageText = "AI Provider"; a.informativeText = "Pick a preset, or choose Custom for any OpenAI-compatible endpoint."
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 150))
        AI.presets.forEach { popup.addItem(withTitle: $0.name) }
        popup.selectItem(withTitle: AI.providerName); popup.target = self; popup.action = #selector(changed)
        func row(_ label: String, _ f: NSTextField, _ y: CGFloat) {
            let l = NSTextField(labelWithString: label); l.frame = NSRect(x: 0, y: y, width: 70, height: 22); l.alignment = .right; v.addSubview(l)
            f.frame = NSRect(x: 78, y: y, width: 282, height: 22); v.addSubview(f)
        }
        popup.frame.origin = CGPoint(x: 78, y: 124); v.addSubview(popup)
        let pl = NSTextField(labelWithString: "Provider"); pl.frame = NSRect(x: 0, y: 126, width: 70, height: 22); pl.alignment = .right; v.addSubview(pl)
        row("Base URL", base, 92); row("Model", model, 64); row("API key", key, 36)
        key.frame.size.width = 222; v.addSubview(PasteHelper.button(for: key, x: 304, y: 36))
        hint.frame = NSRect(x: 78, y: 8, width: 282, height: 20); hint.font = .systemFont(ofSize: 10); hint.textColor = .secondaryLabelColor; v.addSubview(hint)
        base.stringValue = AI.base; model.stringValue = AI.model; key.stringValue = AI.apiKey; updateHint()
        a.accessoryView = v; a.addButton(withTitle: "Save"); a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn {
            let p = AI.presets[popup.indexOfSelectedItem]
            AI.save(name: p.name, kind: p.kind, base: base.stringValue, model: model.stringValue, key: key.stringValue)
            AI.history = []
        }
    }
    @objc func changed() { let p = AI.presets[popup.indexOfSelectedItem]; base.stringValue = p.base; model.stringValue = p.model; updateHint() }
    func updateHint() { let p = AI.presets[popup.indexOfSelectedItem]; hint.stringValue = p.keyURL.isEmpty ? "" : "Get a key: \(p.keyURL)" }
}

// MARK: - HUD View
final class HUDView: NSView, NSTextFieldDelegate {
    let W: CGFloat = 520, H: CGFloat = 260, R: CGFloat = 70   // panel size, ring radius
    var ringGroup = CALayer()
    var outer = CAShapeLayer(), ticks = CAShapeLayer(), arc = CAShapeLayer(), inner = CAShapeLayer(), core = CAShapeLayer()
    var panel = CALayer(), border = CAShapeLayer(), scan = CALayer()
    var title = CATextLayer()
    let input = NSTextField()
    let output = NSTextView()
    static let bodyFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let bodyColor = NSColor(red: 0.7, green: 0.93, blue: 1, alpha: 1)
    let scroll = NSScrollView()
    var onClose: (() -> Void)?
    var onReopen: (() -> Void)?            // a background reply needs the user (confirmation)
    var onBackgroundReply: (() -> Void)?   // a reply finished while the HUD was hidden
    var closing = false

    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; build() }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }

    func ring(_ r: CGFloat, w: CGFloat, c: NSColor, dash: [NSNumber]? = nil, s: CGFloat = 0, e: CGFloat = 1) -> CAShapeLayer {
        let l = CAShapeLayer(); let p = CGMutablePath()
        p.addArc(center: .zero, radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        l.path = p; l.fillColor = nil; l.strokeColor = c.cgColor; l.lineWidth = w
        l.lineDashPattern = dash; l.strokeStart = s; l.strokeEnd = e; l.lineCap = .round
        return l
    }

    func build() {
        let center = CGPoint(x: bounds.width - R - 20, y: bounds.height - R - 20)
        ringGroup.position = center
        ringGroup.bounds = CGRect(x: -R, y: -R, width: R*2, height: R*2)
        ringGroup.shadowColor = CYAN.cgColor; ringGroup.shadowOpacity = 0.9; ringGroup.shadowRadius = 10
        layer?.addSublayer(ringGroup)
        outer = ring(R-4, w: 2, c: CYAN, s: 0, e: 0.72)
        ticks = ring(R-16, w: 8, c: DIM, dash: [3, 8])
        arc   = ring(R-28, w: 3, c: CYAN, s: 0.1, e: 0.35)
        inner = ring(R-42, w: 1.5, c: CYAN, dash: [14, 5])
        core  = ring(R-56, w: 0, c: CYAN); core.fillColor = DIM.cgColor
        [outer, ticks, arc, inner, core].forEach { ringGroup.addSublayer($0) }

        // Panel anchored at its right edge, grows leftward
        panel.anchorPoint = CGPoint(x: 1, y: 1)
        panel.position = CGPoint(x: center.x - R - 12, y: bounds.height - 20)
        panel.bounds = CGRect(x: 0, y: 0, width: 0, height: H)
        panel.backgroundColor = NSColor(red: 0, green: 0.12, blue: 0.22, alpha: 0.78).cgColor
        panel.cornerRadius = 6; panel.masksToBounds = true
        layer?.addSublayer(panel)
        border.fillColor = nil; border.strokeColor = CYAN.cgColor; border.lineWidth = 1.5
        border.path = CGPath(roundedRect: CGRect(x: 1, y: 1, width: W-2, height: H-2), cornerWidth: 6, cornerHeight: 6, transform: nil)
        panel.addSublayer(border)
        scan.backgroundColor = CYAN.withAlphaComponent(0.12).cgColor
        scan.frame = CGRect(x: 0, y: 0, width: W, height: 3); panel.addSublayer(scan)
        title.string = "J.A.R.V.I.S."; title.fontSize = 18
        title.font = NSFont.monospacedSystemFont(ofSize: 18, weight: .bold)
        title.foregroundColor = CYAN.cgColor; title.contentsScale = 2
        title.frame = CGRect(x: 16, y: H - 36, width: 300, height: 24); panel.addSublayer(title)

        // Input
        let px = panel.position.x - W
        input.frame = NSRect(x: px + 16, y: bounds.height - 20 - H + 16, width: W - 32, height: 30)
        input.font = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        input.textColor = .white; input.backgroundColor = NSColor(red: 0, green: 0.2, blue: 0.35, alpha: 0.6)
        input.isBordered = false; input.focusRingType = .none
        input.placeholderAttributedString = NSAttributedString(string: "Ask anything…", attributes: [.foregroundColor: DIM, .font: input.font!])
        input.wantsLayer = true; input.layer?.cornerRadius = 4; input.layer?.borderWidth = 1; input.layer?.borderColor = DIM.cgColor
        input.delegate = self; input.alphaValue = 0
        addSubview(input)

        // Output
        scroll.frame = NSRect(x: px + 16, y: input.frame.maxY + 10, width: W - 32, height: H - 36 - 30 - 30)
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.borderType = .noBorder
        output.frame = scroll.bounds; output.isEditable = false; output.drawsBackground = false
        output.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        output.textColor = NSColor(red: 0.7, green: 0.93, blue: 1, alpha: 1)
        output.autoresizingMask = [.width]; output.isVerticallyResizable = true
        output.textContainer?.widthTracksTextView = true
        scroll.documentView = output; scroll.alphaValue = 0
        addSubview(scroll)
    }

    func spin(_ l: CALayer, _ d: Double, rev: Bool = false) {
        let a = CABasicAnimation(keyPath: "transform.rotation.z")
        a.toValue = (rev ? -1 : 1) * Double.pi * 2; a.duration = d; a.repeatCount = .infinity
        l.add(a, forKey: "spin")
    }

    func show() {
        closing = false
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ringGroup.transform = CATransform3DMakeScale(0.3, 0.3, 1); ringGroup.opacity = 0
        panel.bounds.size.width = 0
        CATransaction.commit()

        CATransaction.begin(); CATransaction.setAnimationDuration(0.4)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        ringGroup.transform = CATransform3DIdentity; ringGroup.opacity = 1
        CATransaction.commit()
        spin(outer, 8); spin(ticks, 14, rev: true); spin(arc, 2.5); spin(inner, 20, rev: true)
        let p = CABasicAnimation(keyPath: "transform.scale"); p.fromValue = 0.9; p.toValue = 1.1
        p.duration = 0.9; p.autoreverses = true; p.repeatCount = .infinity; core.add(p, forKey: "pulse")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard !self.closing else { return }
            CATransaction.begin(); CATransaction.setAnimationDuration(0.45)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
            self.panel.bounds.size.width = self.W
            CATransaction.commit()
            let s = CABasicAnimation(keyPath: "position.y"); s.fromValue = 0; s.toValue = self.H
            s.duration = 1.8; s.repeatCount = .infinity; self.scan.add(s, forKey: "scan")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard !self.closing else { return }
                NSAnimationContext.runAnimationGroup { c in c.duration = 0.25
                    self.input.animator().alphaValue = 1; self.scroll.animator().alphaValue = 1 }
                self.window?.makeFirstResponder(self.input)
            }
        }
    }

    /// Hiding never interrupts JARVIS: a running reply (and any pending confirmation) keeps going in the background.
    func hide(_ done: @escaping () -> Void) {
        closing = true
        input.alphaValue = 0; scroll.alphaValue = 0
        CATransaction.begin(); CATransaction.setAnimationDuration(0.25)
        CATransaction.setCompletionBlock {
            [self.outer, self.ticks, self.arc, self.inner, self.core, self.scan].forEach { $0.removeAllAnimations() }; done()
        }
        panel.bounds.size.width = 0; ringGroup.opacity = 0
        ringGroup.transform = CATransform3DMakeScale(1.4, 1.4, 1)
        CATransaction.commit()
    }

    func append(_ who: String, _ text: String) {
        let a = NSMutableAttributedString(string: "\(who) ", attributes: [.foregroundColor: CYAN, .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)])
        a.append(NSAttributedString(string: text + "\n\n", attributes: [.foregroundColor: HUDView.bodyColor, .font: HUDView.bodyFont]))
        output.textStorage?.append(a)
        output.scrollToEndOfDocument(nil)
    }

    /// Pending risky-action confirmation: ⏎ allows, ⎋ denies, closing the HUD denies.
    var pendingConfirm: ((Bool) -> Void)?
    func askConfirm(_ q: String, _ decide: @escaping (Bool) -> Void) {
        pendingConfirm = decide
        title.string = "J.A.R.V.I.S.  — ⏎ ALLOW  ⎋ DENY"
        let a = NSAttributedString(string: "⚠ " + q.replacingOccurrences(of: "\n\n", with: "  ") + "\n", attributes: [.foregroundColor: NSColor(red: 1, green: 0.75, blue: 0.3, alpha: 1), .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)])
        if let s = output.string.range(of: "…\n\n", options: .backwards) { output.textStorage?.insert(a, at: output.string.distance(from: output.string.startIndex, to: s.lowerBound)) }
        output.scrollToEndOfDocument(nil)
        input.placeholderString = "Press Return to allow, Esc to deny"
        window?.makeFirstResponder(input)
    }
    func resolveConfirm(_ ok: Bool) {
        guard let d = pendingConfirm else { return }
        pendingConfirm = nil; input.placeholderString = "Ask anything…"
        title.string = "J.A.R.V.I.S.  — " + (ok ? "WORKING" : "THINKING")
        d(ok)
    }

    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if pendingConfirm != nil {
            if sel == #selector(NSResponder.cancelOperation(_:)) { resolveConfirm(false); return true }
            if sel == #selector(NSResponder.insertNewline(_:)) { resolveConfirm(true); return true }
        }
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            if AI.busy { AI.stop(); return true }   // first Esc stops the reply, second closes the HUD (the hotkey hides without stopping)
            onClose?(); return true
        }
        if sel == #selector(NSResponder.insertNewline(_:)) { submit(input.stringValue); return true }
        return false
    }

    func submit(_ text: String, spoken: Bool = false) {
            let q = text.trimmingCharacters(in: .whitespaces); guard !q.isEmpty else { return }
            guard !AI.busy else { return }
            input.stringValue = ""; append(spoken ? "YOU 🎙 ▸" : "YOU ▸", q); append("JARVIS ▸", "…")
            input.placeholderString = "Esc to stop"
            AI.spoken = spoken
            title.string = "J.A.R.V.I.S.  — THINKING"
            AI.onStatus = { [weak self] st in self?.title.string = "J.A.R.V.I.S.  — \(st)" }
            AI.onConfirm = { [weak self] q, decide in
                guard let self = self else { decide(false); return }
                if self.window?.isVisible != true { self.onReopen?() }   // bring the HUD back so the question can be answered
                self.askConfirm(q, decide)
            }
            AI.onStep = { [weak self] st in
                guard let self = self else { return }
                let a = NSAttributedString(string: st + "\n", attributes: [.foregroundColor: DIM.withAlphaComponent(0.9), .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)])
                if let s = self.output.string.range(of: "…\n\n", options: .backwards) { self.output.textStorage?.insert(a, at: self.output.string.distance(from: self.output.string.startIndex, to: s.lowerBound)) }
                self.output.scrollToEndOfDocument(nil)
            }
            AI.ask(q) { r in
                self.title.string = "J.A.R.V.I.S."; self.input.placeholderString = "Ask anything…"
                if self.window?.isVisible != true { self.onBackgroundReply?() }
                if let s = self.output.string.range(of: "…\n\n", options: .backwards) {
                    self.output.textStorage?.replaceCharacters(in: NSRange(s, in: self.output.string), with: NSAttributedString(string: r + "\n\n", attributes: [.foregroundColor: HUDView.bodyColor, .font: HUDView.bodyFont]))
                    self.output.scrollToEndOfDocument(nil)
                }
            }
    }
}

// MARK: - Window
final class HUDPanel: NSPanel {
    let hud: HUDView
    init(screen: NSScreen) {
        let f = screen.visibleFrame
        let r = NSRect(x: f.maxX - 720, y: f.maxY - 320, width: 720, height: 320)
        hud = HUDView(frame: NSRect(origin: .zero, size: r.size))
        super.init(contentRect: r, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; level = .floating; hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isFloatingPanel = true; hidesOnDeactivate = false
        contentView = hud
    }
    func place(on screen: NSScreen) {
        let f = screen.visibleFrame
        setFrameOrigin(NSPoint(x: f.maxX - 720, y: f.maxY - 320))
    }
    override var canBecomeKey: Bool { true }
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return super.performKeyEquivalent(with: e) }
        let map: [String: Selector] = ["v": #selector(NSText.paste(_:)), "c": #selector(NSText.copy(_:)), "x": #selector(NSText.cut(_:)),
                                       "a": #selector(NSText.selectAll(_:)), "z": Selector(("undo:"))]
        if let sel = map[e.charactersIgnoringModifiers ?? ""] { return NSApp.sendAction(sel, to: nil, from: self) }
        return super.performKeyEquivalent(with: e)
    }
}

// MARK: - App
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var panel: HUDPanel?
    var overlay: OverlayWindow?
    var tap: CFMachPort?
    var active = false

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "◎"
        if let k = UserDefaults.standard.string(forKey: "geminiKey"), AI.d.string(forKey: "aiKey") == nil {
            AI.save(name: "Gemini", kind: .gemini, base: AI.presets[1].base, model: UserDefaults.standard.string(forKey: "geminiModel") ?? "gemini-2.5-flash", key: k)
        }
        buildMenu()
        Guard.Watcher.shared.onResult = { [weak self] f, v, d in self?.downloadChecked(f, v, d) }
        Guard.Watcher.shared.start()
        // Edit menu so Cmd+V/C/X/A work in dialogs
        let main = NSMenu(); let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = main
        installTap()
        setupVoice()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            for d in [0.3, 1.2, 2.5] { DispatchQueue.main.asyncAfter(deadline: .now() + d) { self.overlay?.relayout() } }
        }
    }

    func setupVoice() {
        let v = Voice.shared
        v.onStateChange = { [weak self] in self?.refreshIcon(); self?.buildMenu() }
        v.onWake = { [weak self] in guard let self = self else { return }; if !self.active { self.showHUD() }; self.panel?.hud.title.string = "J.A.R.V.I.S.  — LISTENING" }
        v.onPartial = { [weak self] q in self?.panel?.hud.input.stringValue = q }
        v.onQuestion = { [weak self] q in guard let self = self else { return }; if !self.active { self.showHUD() }; self.panel?.hud.submit(q, spoken: true) }
        v.apply()
        Memory.prune()
    }
    func refreshIcon() { statusItem.button?.title = Voice.shared.listening ? "◎ 🎙" : "◎" }

    func buildMenu() {
        let m = NSMenu()
        m.addItem(withTitle: "Toggle HUD   (⌥ Space)", action: #selector(toggle), keyEquivalent: "")
        m.addItem(withTitle: "Toggle Telemetry   (⌃⌥ Space)", action: #selector(toggleOverlay), keyEquivalent: "")
        let fan = NSMenu(title: "Fans"); let fanItem = NSMenuItem(title: "Fans", action: nil, keyEquivalent: ""); fanItem.submenu = fan; m.addItem(fanItem)
        fan.addItem(withTitle: "Automatic", action: #selector(fanAuto), keyEquivalent: "")
        for r in [1500, 2500, 3500, 4500, 5500] { let i = fan.addItem(withTitle: "\(r) rpm", action: #selector(fanSet(_:)), keyEquivalent: ""); i.tag = r }
        fan.addItem(withTitle: "Maximum", action: #selector(fanMax), keyEquivalent: "")
        fan.addItem(.separator())
        fan.addItem(withTitle: FanControl.installed ? "Helper installed ✓" : "Install Fan Control Helper…", action: #selector(fanInstall), keyEquivalent: "")
        let vm = NSMenu(title: "Wake Word"); let vi = NSMenuItem(title: "Wake Word \"Jarvis\"  (\(Voice.shared.listening ? "listening" : "off"))", action: nil, keyEquivalent: ""); vi.submenu = vm; m.addItem(vi)
        for (t, mode) in [("Automatic (when plugged in)", Voice.Mode.auto), ("Always On", .on), ("Off", .off)] {
            let i = vm.addItem(withTitle: t, action: #selector(setVoice(_:)), keyEquivalent: ""); i.representedObject = mode.rawValue; i.state = Voice.shared.mode == mode ? .on : .off
        }
        vm.addItem(.separator())
        let lm = NSMenu(title: "Languages"); let li = NSMenuItem(title: "Languages  (\(Voice.shared.locales.count))", action: nil, keyEquivalent: ""); li.submenu = lm; vm.addItem(li)
        for l in Voice.languages {
            let onDevice = SFSpeechRecognizer(locale: Locale(identifier: l.id))?.supportsOnDeviceRecognition == true
            let i = lm.addItem(withTitle: "\(l.name)   “\(l.wakes[0])”" + (onDevice ? "" : "   (server)"), action: #selector(toggleLanguage(_:)), keyEquivalent: ""); i.representedObject = l.id
            i.state = Voice.shared.locales.contains(l.id) ? .on : .off
            if !onDevice { i.toolTip = "Not downloaded for on-device use: audio would go to Apple's servers and is limited per day. To make it on-device, add it under System Settings → Keyboard → Dictation → Languages." }
        }
        vm.addItem(.separator()); vm.addItem(withTitle: "Forget Today's Transcript", action: #selector(forgetTranscript), keyEquivalent: "")
        vm.addItem(withTitle: "Forget Everything Heard", action: #selector(forgetAllHeard), keyEquivalent: "")
        vm.addItem(withTitle: "Forget Remembered Notes", action: #selector(forgetNotes), keyEquivalent: "")
        vm.addItem(withTitle: "Show Memory Folder", action: #selector(showMemory), keyEquivalent: "")
        m.addItem(withTitle: "Clean Up Disk…", action: #selector(cleanDisk), keyEquivalent: "")
        let wd = m.addItem(withTitle: "Check New Downloads Automatically", action: #selector(toggleWatch), keyEquivalent: ""); wd.state = Guard.Watcher.shared.enabled ? .on : .off
        m.addItem(withTitle: "VirusTotal Key…  (\(Installer.vtKey.isEmpty ? "not set" : "set"))", action: #selector(setVT), keyEquivalent: "")
        let c = m.addItem(withTitle: "Ask Before Risky Actions", action: #selector(toggleConfirm), keyEquivalent: ""); c.state = Agent.confirmActions ? .on : .off
        m.addItem(withTitle: "Web Search…  (\(Search.provider))", action: #selector(setSearch), keyEquivalent: "")
        m.addItem(withTitle: "AI Provider…  (\(AI.providerName) · \(AI.model))", action: #selector(setProvider), keyEquivalent: "")
        m.addItem(withTitle: "Clear Conversation", action: #selector(clear), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = m
    }

    func prompt(_ msg: String, _ def: String, secure: Bool = false) -> String? {
        let a = NSAlert(); a.messageText = msg
        let tf: NSTextField = secure ? NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24)) : NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        tf.stringValue = def; a.accessoryView = tf
        a.addButton(withTitle: "Save"); a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertFirstButtonReturn ? tf.stringValue : nil
    }
    let providerDialog = ProviderDialog(), searchDialog = SearchDialog()
    @objc func toggleLanguage(_ i: NSMenuItem) { Voice.shared.toggleLocale(i.representedObject as! String); buildMenu() }
    @objc func setVoice(_ i: NSMenuItem) { Voice.shared.mode = Voice.Mode(rawValue: i.representedObject as! String)! }
    @objc func forgetTranscript() { Memory.forgetToday() }
    @objc func forgetAllHeard() { Memory.forgetAllHeard() }
    @objc func forgetNotes() { Memory.forgetAllNotes() }
    @objc func toggleWatch() { UserDefaults.standard.set(!Guard.Watcher.shared.enabled, forKey: "watchDownloads"); buildMenu() }
    /// Result of the automatic download check: quiet one-liner for clean files, full HUD with details for anything off.
    func downloadChecked(_ file: String, _ verdict: String, _ detail: String) {
        let name = (file as NSString).lastPathComponent
        let ok = verdict.hasPrefix("PASS")
        if !active { showHUD() }
        let msg = ok ? "I checked \(name) the moment it finished downloading: signed and notarized by Apple, no issues. Safe to open."
                     : "Hold on, sir. \(name) just landed in \((file as NSString).deletingLastPathComponent.replacingOccurrences(of: Guard.home, with: "~")) and it does not pass my checks: \(verdict)\n\(detail.split(separator: "\n").filter { $0.contains("→") || $0.contains("VirusTotal") || $0.contains("ClamAV") || $0.contains("No .app") }.joined(separator: "\n"))\nI would not open it. Say \"quarantine it\" and I will put it out of reach, or ask me to look into it."
        panel?.hud.append("JARVIS ▸", msg)
        Memory.log("[download check] \(name): \(verdict)")
        if ok { DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in if self?.panel?.hud.window?.isVisible == true && self?.panel?.hud.pendingConfirm == nil { self?.hideHUD() } } }
    }
    @objc func setVT() {
        let a = NSAlert(); a.messageText = "VirusTotal API key"; a.informativeText = "Used to look up the hash of every download before an install (the file itself is never uploaded). Free key: virustotal.com → Sign up → API key."
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        let f = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 296, height: 24)); f.stringValue = Installer.vtKey; v.addSubview(f); v.addSubview(PasteHelper.button(for: f, x: 304, y: 1)); a.accessoryView = v
        a.addButton(withTitle: "Save"); a.addButton(withTitle: "Cancel"); NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { UserDefaults.standard.set(f.stringValue.trimmingCharacters(in: .whitespaces), forKey: "vtKey"); buildMenu() }
    }
    @objc func cleanDisk() {
        if !active { showHUD() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.panel?.hud.submit("Scan my disk: tell me what is using it, what is safe to clean, what can be cleaned but would make something slower, and what you will not touch. Then propose a clean-up.") }
    }
    @objc func showMemory() { NSWorkspace.shared.open(Memory.dir) }
    @objc func toggleConfirm() { Agent.confirmActions.toggle(); buildMenu() }
    @objc func setSearch() { searchDialog.run(); buildMenu() }
    @objc func setProvider() { providerDialog.run(); buildMenu() }
    @objc func clear() { AI.history = []; panel?.hud.output.string = "" }

    func installTap() {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        let cb: CGEventTapCallBack = { _, type, event, refcon in
            let me = Unmanaged<AppDelegate>.fromOpaque(refcon!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }; return Unmanaged.passUnretained(event)
            }
            // ⌥ Space (keycode 49) toggles the HUD. F5 is intentionally left alone.
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags.intersection([.maskAlternate, .maskCommand, .maskControl, .maskShift])
            if code == 49 && flags == .maskAlternate {
                DispatchQueue.main.async { me.toggle() }; return nil
            }
            if code == 49 && flags == [.maskAlternate, .maskControl] {
                DispatchQueue.main.async { me.toggleOverlay() }; return nil
            }
            return Unmanaged.passUnretained(event)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: cb, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            let a = NSAlert(); a.messageText = "Accessibility permission needed"
            a.informativeText = "Enable JarvisHUD in System Settings → Privacy & Security → Accessibility and Input Monitoring, then relaunch."
            a.runModal(); return
        }
        tap = t
        CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
    }

    @objc func toggle() { active ? hideHUD() : showHUD() }
    @objc func fanAuto() { notify(FanControl.set(nil)) }
    @objc func fanSet(_ i: NSMenuItem) { notify(FanControl.set(Double(i.tag))) }
    @objc func fanMax() { notify(FanControl.set(SMC.shared.fanRange(0).1)) }
    @objc func fanInstall() { FanControl.install(); buildMenu() }
    func notify(_ s: String, seconds: Double = 4) { statusItem.button?.title = "◎ " + s; DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { self.refreshIcon() } }
    func applicationWillTerminate(_ n: Notification) { if Stats.shared.snap.fanManual { FanControl.set(nil) } }

    private var overlayClosing = false
    @objc func toggleOverlay() {
        if let o = overlay {
            if overlayClosing {   // clicked again mid fade-out: bring the same window back instead of stacking a new one
                overlayClosing = false; o.view.start()
                NSAnimationContext.runAnimationGroup { c in c.duration = 0.2; o.animator().alphaValue = 1 }
                return
            }
            overlayClosing = true; o.view.stop()
            NSAnimationContext.runAnimationGroup({ c in c.duration = 0.3; o.animator().alphaValue = 0 }) { [weak self] in
                guard let self = self, self.overlay === o, self.overlayClosing else { return }   // superseded: leave the live one alone
                o.orderOut(nil); self.overlay = nil; self.overlayClosing = false
            }
        } else if let screen = NSScreen.main {
            let o = OverlayWindow(screen: screen); overlay = o
            o.alphaValue = 0; o.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { c in c.duration = 0.3; o.animator().alphaValue = 1 }
            o.relayout()
        }
    }

    /// One HUD for the life of the app: hiding it just orders the window out, so a reply that is still
    /// running keeps its output and lands in the same transcript when the HUD comes back.
    func showHUD() {
        guard let screen = NSScreen.main else { return }
        active = true
        let p: HUDPanel
        if let existing = panel { p = existing; p.place(on: screen) }
        else {
            p = HUDPanel(screen: screen); panel = p
            // show the tail of the remembered conversation so the context is visible after a restart
            let prior = AI.history.suffix(8)
            if !prior.isEmpty {
                for m in prior { p.hud.append(m.role == "user" ? "YOU ▸" : "JARVIS ▸", String(m.text.prefix(600))) }
                p.hud.append("", "— earlier conversation, still remembered —")
            }
            p.hud.onClose = { [weak self] in self?.hideHUD() }
            p.hud.onReopen = { [weak self] in if self?.active == false { self?.showHUD() } }
            p.hud.onBackgroundReply = { [weak self] in self?.notify("JARVIS replied", seconds: 10) }
        }
        statusItem.button?.title = Voice.shared.listening ? "◎ 🎙" : "◎"
        p.makeKeyAndOrderFront(nil)
        p.hud.show()
    }
    func hideHUD() {
        guard active, let p = panel else { return }
        active = false
        p.hud.hide { [weak self] in if self?.active == false { p.orderOut(nil) } }   // re-opened mid-fade: leave it up
    }
}

let app = NSApplication.shared
let d = AppDelegate(); app.delegate = d
app.setActivationPolicy(.accessory)
app.run()
