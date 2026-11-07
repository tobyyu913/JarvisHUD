import Cocoa
import Speech
import AVFoundation
import IOKit.ps

/// Always-on wake-word listener using on-device speech recognition.
/// Modes: auto (listen while on AC power), on, off.
/// Small diagnostic log (Application Support/JarvisHUD/voice-debug.log): state changes and errors only.
func vlog(_ m: String) {
    let line = "\(Date()) \(m)\n"; let f = Memory.dir.appendingPathComponent("voice-debug.log")
    if let h = try? FileHandle(forWritingTo: f) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() } else { try? line.write(to: f, atomically: true, encoding: .utf8) }
}

/// One speech recognizer for one language. Several run side by side on the same microphone buffers.
final class Recog {
    let locale: String
    let recognizer: SFSpeechRecognizer?
    var request: SFSpeechAudioBufferRecognitionRequest?
    var task: SFSpeechRecognitionTask?
    var lastText = "", lastConf: Float = 0, generation = 0
    init(_ l: String) { locale = l; recognizer = SFSpeechRecognizer(locale: Locale(identifier: l)) }
    var available: Bool { recognizer?.isAvailable == true }
}

final class Voice: NSObject {
    static let shared = Voice()
    enum Mode: String { case auto, on, off }
    var mode: Mode {
        get { Mode(rawValue: UserDefaults.standard.string(forKey: "voiceMode") ?? "auto") ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "voiceMode"); apply() }
    }
    /// Languages JARVIS listens in. Each costs one on-device recognizer (a little CPU); the wake word is per language.
    static let languages: [(id: String, name: String, wakes: [String])] = [
        ("en-US", "English", ["jarvis", "jervis", "travis,", "hey travis"]),
        ("zh-CN", "中文（简体）", ["贾维斯", "加维斯", "贾维思", "家维斯", "jarvis"]),
        ("zh-TW", "中文（繁體）", ["賈維斯", "加維斯", "賈維思", "jarvis"]),
        ("yue-CN", "粵語", ["賈維斯", "贾维斯", "jarvis"]),
        ("ja-JP", "日本語", ["ジャービス", "ジャーヴィス", "jarvis"]),
        ("ko-KR", "한국어", ["자비스", "jarvis"]),
        ("es-ES", "Español", ["jarvis"]), ("fr-FR", "Français", ["jarvis"]), ("de-DE", "Deutsch", ["jarvis"]),
        ("it-IT", "Italiano", ["jarvis"]), ("pt-BR", "Português", ["jarvis"]), ("ru-RU", "Русский", ["джарвис", "jarvis"]),
        ("hi-IN", "हिन्दी", ["जार्विस", "jarvis"]), ("ar-SA", "العربية", ["جارفيس", "jarvis"]),
    ]
    /// Default: English plus the user's system languages that can be recognised on-device.
    static var defaultLocales: [String] {
        var out = ["en-US"]
        for pref in Locale.preferredLanguages {
            if let l = languages.first(where: { $0.id.hasPrefix(String(pref.prefix(2))) && (pref.hasPrefix("zh-Hant") ? $0.id == "zh-TW" : pref.hasPrefix("zh") ? $0.id == "zh-CN" : true) }),
               !out.contains(l.id), SFSpeechRecognizer(locale: Locale(identifier: l.id))?.supportsOnDeviceRecognition == true { out.append(l.id) }
        }
        return out
    }
    var locales: [String] {
        get { UserDefaults.standard.stringArray(forKey: "voiceLocales") ?? Voice.defaultLocales }
        set { UserDefaults.standard.set(newValue.isEmpty ? ["en-US"] : newValue, forKey: "voiceLocales"); if listening { stop(); start() }; onStateChange?() }
    }
    func toggleLocale(_ id: String) { var l = locales; if let i = l.firstIndex(of: id) { l.remove(at: i) } else { l.append(id) }; locales = l }

    private(set) var listening = false
    var onStateChange: (() -> Void)?
    var onWake: (() -> Void)?                 // show HUD
    var onPartial: ((String) -> Void)?        // live text of the question being spoken
    var onQuestion: ((String) -> Void)?       // final question to ask

    // Everything the mic hears is appended to the persistent day log (see Memory).
    func recentTranscript(minutes: Double = 30, maxChars: Int = 2500) -> String { Memory.transcript(hours: minutes / 60, maxChars: maxChars) }

    private let engine = AVAudioEngine()
    private var recogs: [Recog] = []
    private var restartTimer: Timer?, silenceTimer: Timer?, commitTimer: Timer?
    private var lastCommitted = "", capturing = false, captureStart: String.Index? = nil, captureRecog: Recog? = nil, wakeAt = Date.distantPast
    private var pendingFinal: (text: String, conf: Float)? = nil
    private var powerSource: CFRunLoopSource?

    static var onACPower: Bool {
        guard let t = IOPSGetProvidingPowerSourceType(nil)?.takeRetainedValue() as String? else { return true }
        return t == kIOPMACPowerKey
    }

    override init() {
        super.init()
        // Re-evaluate when power source changes
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            let me = Unmanaged<Voice>.fromOpaque(ctx!).takeUnretainedValue(); DispatchQueue.main.async { me.apply() }
        }, ctx)?.takeRetainedValue() {
            powerSource = src; CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }
    }

    var shouldListen: Bool { mode == .on || (mode == .auto && Voice.onACPower) }

    func apply() {
        vlog("apply mode=\(mode) ac=\(Voice.onACPower) should=\(shouldListen) listening=\(listening)")
        if shouldListen && !listening { start() } else if !shouldListen && listening { stop() }
        onStateChange?()
    }

    func start() {
        guard !listening else { return }
        SFSpeechRecognizer.requestAuthorization { auth in
            vlog("speech auth \(auth.rawValue)")
            guard auth == .authorized else { DispatchQueue.main.async { self.deny("Speech recognition") }; return }
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                vlog("mic \(ok)")
                DispatchQueue.main.async { ok ? self.begin() : self.deny("Microphone") }
            }
        }
    }
    private func deny(_ what: String) {
        mode = .off
        let a = NSAlert(); a.messageText = "\(what) access needed"
        a.informativeText = "Enable JarvisHUD in System Settings → Privacy & Security → \(what), then turn the wake word back on from the ◎ menu."
        a.runModal()
    }

    private func begin() {
        guard !listening else { return }
        recogs = locales.map(Recog.init)
        vlog("begin locales=\(locales) available=\(recogs.map { "\($0.locale):\($0.available)/\($0.recognizer?.supportsOnDeviceRecognition == true)" })")
        guard recogs.contains(where: { $0.available }) else {
            // recognizer not ready yet (common right after launch): retry
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in if self?.shouldListen == true { self?.begin() } }
            return
        }
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else { return }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: fmt) { [weak self] buf, _ in self?.recogs.forEach { $0.request?.append(buf) } }
        engine.prepare()
        do { try engine.start() } catch { vlog("audio engine: \(error)"); return }
        listening = true
        newTasks()
        onStateChange?()
    }

    func stop() {
        guard listening else { return }
        listening = false; capturing = false; captureRecog = nil
        restartTimer?.invalidate(); silenceTimer?.invalidate(); commitTimer?.invalidate()
        for r in recogs { r.task?.cancel(); r.task = nil; r.request?.endAudio(); r.request = nil }
        engine.inputNode.removeTap(onBus: 0); engine.stop()
        onStateChange?()
    }

    /// Recognition tasks are limited to ~1 minute; rotate them all together. Also called after a question is captured.
    private func newTasks() {
        for r in recogs { newTask(r) }
        restartTimer?.invalidate()
        restartTimer = Timer.scheduledTimer(withTimeInterval: 50, repeats: false) { [weak self] _ in
            guard let self = self, self.listening, !self.capturing else { return }
            self.commitBest(); self.newTasks()
        }
    }
    private func newTask(_ r: Recog) {
        r.task?.cancel(); r.request?.endAudio()
        guard let rec = r.recognizer, rec.isAvailable else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        req.taskHint = .dictation
        if #available(macOS 13, *) { req.addsPunctuation = false }
        r.request = req; r.lastText = ""; r.lastConf = 0
        r.generation += 1; let gen = r.generation
        r.task = rec.recognitionTask(with: req) { [weak self, weak r] res, err in
            guard let self = self, let r = r, self.listening, gen == r.generation else { return }
            if let e = err { vlog("task error (\(r.locale)): \(e)") }
            if let res = res {
                let segs = res.bestTranscription.segments
                let conf = segs.isEmpty ? 0 : segs.map { $0.confidence }.reduce(0, +) / Float(segs.count)
                self.handle(res.bestTranscription.formattedString, conf: conf, final: res.isFinal, from: r)
            }
            if err != nil || res?.isFinal == true {
                // restart shortly (not while a question is mid-capture)
                DispatchQueue.main.asyncAfter(deadline: .now() + (self.capturing ? 0.8 : 0.2)) { if self.listening { self.newTask(r) } }
            }
        }
    }

    /// With several languages listening, each produces its own transcript of the same audio. Log only the most
    /// confident one (the wrong-language recognizers produce short, low-confidence gibberish).
    private func commitBest() {
        guard let best = recogs.filter({ !$0.lastText.trimmingCharacters(in: .whitespaces).isEmpty }).max(by: { ($0.lastConf, $0.lastText.count) < ($1.lastConf, $1.lastText.count) }) else { return }
        commit(best.lastText)
    }
    private func commit(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty && t != lastCommitted { Memory.log(t); lastCommitted = t }
    }

    private func handle(_ text: String, conf: Float, final: Bool, from r: Recog) {
        r.lastText = text; if final || conf > 0 { r.lastConf = conf }
        let lower = text.lowercased()
        if !capturing {
            let wakes = Voice.languages.first { $0.id == r.locale }?.wakes ?? ["jarvis"]
            if let w = wakes.compactMap({ lower.range(of: $0, options: .backwards) }).first, Date().timeIntervalSince(wakeAt) > 2 {
                wakeAt = Date(); capturing = true; captureStart = w.upperBound; captureRecog = r
                DispatchQueue.main.async { self.onWake?() }
                armSilence()
            }
        }
        if capturing, captureRecog === r, let st = captureStart, st <= text.endIndex {
            let q = String(text[st...]).trimmingCharacters(in: CharacterSet(charactersIn: " ,.?!，。？！"))
            DispatchQueue.main.async { self.onPartial?(q) }
            armSilence()
        }
        if final && !capturing {
            // finals from the different recognizers arrive within a second of each other: keep the best, log once
            DispatchQueue.main.async {
                if (self.pendingFinal?.conf ?? -1, self.pendingFinal?.text.count ?? 0) < (conf, text.count) { self.pendingFinal = (text, conf) }
                self.commitTimer?.invalidate()
                self.commitTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
                    guard let self = self, let p = self.pendingFinal else { return }
                    self.pendingFinal = nil; self.commit(p.text)
                }
            }
        }
    }

    private func armSilence() {
        DispatchQueue.main.async {
            self.silenceTimer?.invalidate()
            self.silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: false) { [weak self] _ in self?.finishCapture() }
        }
    }
    private func finishCapture() {
        guard capturing, let r = captureRecog, let st = captureStart else { return }
        let text = r.lastText
        let q = st <= text.endIndex ? String(text[st...]).trimmingCharacters(in: CharacterSet(charactersIn: " ,.?!，。？！")) : ""
        capturing = false; captureStart = nil; captureRecog = nil
        commit(text)
        // ignore a bare wake word: need either two words or (for CJK, where there are no spaces) a few characters
        if q.split(separator: " ").count >= 2 || q.count >= 3 { onQuestion?(q) }
        newTasks()
    }
}
