import Cocoa
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
- You have live telemetry about this Mac appended below; use it when asked about the machine's status, fans, temperatures, battery, memory, processes, network, etc.
- Web search: SEARCH_INSTRUCTION
- You CAN control the cooling fans. When the user asks to change fan speed, include exactly one command tag at the very end of your reply: [FAN:AUTO] to return fans to automatic, or [FAN:<rpm>] for a fixed speed (e.g. [FAN:3500]). Choose a sensible rpm within the fan's range if the user is vague ("max" = the max rpm, "quiet" = minimum, "cool it down" = ~70% of max). Only emit a tag when the user actually requests a change. The tag is stripped before display; confirm the action in your sentence.
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
    static var history: [(role: String, text: String)] = []

    static var onStatus: ((String) -> Void)?
    static func ask(_ prompt: String, done: @escaping (String) -> Void) {
        request(prompt) { r in
            if Search.enabled, let m = r.range(of: #"\[SEARCH:([^\]]+)\]"#, options: .regularExpression) {
                let q = String(r[m].dropFirst(8).dropLast()).trimmingCharacters(in: .whitespaces)
                onStatus?("SEARCHING: \(q)")
                Search.run(q) { results in
                    onStatus?("THINKING")
                    request("Web search results for \"\(q)\":\n\(results)\n\nNow answer the previous question using these results. Cite the source site name briefly when useful. Do not emit another [SEARCH] tag.") { r2 in
                        done(r2.replacingOccurrences(of: #"\[SEARCH:[^\]]+\]"#, with: "", options: .regularExpression)) }
                }
            } else { done(r) }
        }
    }
    static func request(_ prompt: String, done: @escaping (String) -> Void) {
        let localhost = base.contains("localhost") || base.contains("127.0.0.1")
        guard !apiKey.isEmpty || localhost else { done("No API key, sir. Use the menu bar ◎ → AI Provider…"); return }
        history.append(("user", prompt))
        let searchRule = Search.enabled
            ? "You can search the web. If the question needs current, factual or external information you don't reliably know (news, prices, weather, docs, recent events), reply with ONLY a tag [SEARCH:<concise query>] and nothing else; you will receive the results and then answer. Do not search for things about this Mac or for casual conversation. Never search twice in a row."
            : "You cannot browse the web. If asked for current information, say so briefly."
        let system = JARVIS_PROMPT.replacingOccurrences(of: "SEARCH_INSTRUCTION", with: searchRule) + "\n\nLive telemetry for this Mac right now: " + Stats.shared.refresh().summary
        let b = base.hasSuffix("/") ? String(base.dropLast()) : base
        var req: URLRequest; var body: [String: Any]
        switch kind {
        case .openai:
            req = URLRequest(url: URL(string: b + "/chat/completions")!)
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            body = ["model": model, "messages": [["role": "system", "content": system]] + history.map { ["role": $0.role, "content": $0.text] }, "max_tokens": 1024]
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
        URLSession.shared.dataTask(with: req) { data, _, err in
            var text = "Error: \(err?.localizedDescription ?? "no response")"
            if let d = data, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                if let t = parse(j) { text = t.trimmingCharacters(in: .whitespacesAndNewlines); history.append(("assistant", text)) }
                else if let e = j["error"] as? [String: Any], let m = e["message"] as? String { text = "Error: \(m)" }
                else if let e = j["error"] as? String { text = "Error: \(e)" }
                else { text = "Error: unexpected response from \(providerName)" }
            }
            DispatchQueue.main.async { done(text) }
        }.resume()
    }
    static func parse(_ j: [String: Any]) -> String? {
        switch kind {
        case .openai: return ((j["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
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
        key.stringValue = Search.apiKey; v.addSubview(key)
        hint.frame = NSRect(x: 78, y: 10, width: 282, height: 20); hint.font = .systemFont(ofSize: 10); hint.textColor = .secondaryLabelColor; v.addSubview(hint); changed()
        a.accessoryView = v; a.addButton(withTitle: "Save"); a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { Search.d.set(popup.titleOfSelectedItem, forKey: "searchProvider"); Search.d.set(key.stringValue, forKey: "searchKey") }
    }
    @objc func changed() { let p = Search.presets[popup.indexOfSelectedItem]; hint.stringValue = p.keyURL.isEmpty ? "" : "Get a key: \(p.keyURL)"; key.isEnabled = !p.keyURL.isEmpty }
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
    let scroll = NSScrollView()
    var onClose: (() -> Void)?

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
            CATransaction.begin(); CATransaction.setAnimationDuration(0.45)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
            self.panel.bounds.size.width = self.W
            CATransaction.commit()
            let s = CABasicAnimation(keyPath: "position.y"); s.fromValue = 0; s.toValue = self.H
            s.duration = 1.8; s.repeatCount = .infinity; self.scan.add(s, forKey: "scan")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                NSAnimationContext.runAnimationGroup { c in c.duration = 0.25
                    self.input.animator().alphaValue = 1; self.scroll.animator().alphaValue = 1 }
                self.window?.makeFirstResponder(self.input)
            }
        }
    }

    func hide(_ done: @escaping () -> Void) {
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
        a.append(NSAttributedString(string: text + "\n\n", attributes: [.foregroundColor: output.textColor!, .font: output.font!]))
        output.textStorage?.append(a)
        output.scrollToEndOfDocument(nil)
    }

    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) { onClose?(); return true }
        if sel == #selector(NSResponder.insertNewline(_:)) {
            let q = input.stringValue.trimmingCharacters(in: .whitespaces); guard !q.isEmpty else { return true }
            input.stringValue = ""; append("YOU ▸", q); append("JARVIS ▸", "…")
            title.string = "J.A.R.V.I.S.  — THINKING"
            AI.onStatus = { [weak self] st in self?.title.string = "J.A.R.V.I.S.  — \(st)" }
            AI.ask(q) { raw in
                var r = raw
                if let m = r.range(of: #"\[FAN:(AUTO|[0-9]+)\]"#, options: [.regularExpression, .caseInsensitive]) {
                    let tag = r[m].dropFirst(5).dropLast().uppercased(); r.removeSubrange(m); r = r.trimmingCharacters(in: .whitespacesAndNewlines)
                    r += "\n[" + FanControl.set(tag == "AUTO" ? nil : Double(tag)) + "]"
                }
                self.title.string = "J.A.R.V.I.S."
                if let s = self.output.string.range(of: "…\n\n", options: .backwards) {
                    self.output.textStorage?.replaceCharacters(in: NSRange(s, in: self.output.string), with: r + "\n\n")
                    self.output.scrollToEndOfDocument(nil)
                }
            }
            return true
        }
        return false
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
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            for d in [0.3, 1.2, 2.5] { DispatchQueue.main.asyncAfter(deadline: .now() + d) { self.overlay?.relayout() } }
        }
    }

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
            // ⌥ Space (keycode 49) toggles. Also F5 (96) for Siri-key replacement.
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags.intersection([.maskAlternate, .maskCommand, .maskControl, .maskShift])
            if (code == 49 && flags == .maskAlternate) || code == 96 {
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
    func notify(_ s: String) { statusItem.button?.title = "◎ " + s; DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.statusItem.button?.title = "◎" } }
    func applicationWillTerminate(_ n: Notification) { if Stats.shared.snap.fanManual { FanControl.set(nil) } }

    @objc func toggleOverlay() {
        if let o = overlay {
            o.view.stop()
            NSAnimationContext.runAnimationGroup({ c in c.duration = 0.3; o.animator().alphaValue = 0 }) { o.orderOut(nil); self.overlay = nil }
        } else if let screen = NSScreen.main {
            let o = OverlayWindow(screen: screen); overlay = o
            o.alphaValue = 0; o.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { c in c.duration = 0.3; o.animator().alphaValue = 1 }
            o.relayout()
        }
    }

    func showHUD() {
        guard !active, let screen = NSScreen.main else { return }
        active = true
        let p = HUDPanel(screen: screen); panel = p
        p.hud.onClose = { [weak self] in self?.hideHUD() }
        p.makeKeyAndOrderFront(nil)
        p.hud.show()
    }
    func hideHUD() {
        guard active, let p = panel else { return }
        p.hud.hide { p.orderOut(nil); self.panel = nil; self.active = false }
    }
}

let app = NSApplication.shared
let d = AppDelegate(); app.delegate = d
app.setActivationPolicy(.accessory)
app.run()
