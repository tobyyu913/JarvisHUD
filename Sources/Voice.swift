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

final class Voice: NSObject {
    static let shared = Voice()
    enum Mode: String { case auto, on, off }
    var mode: Mode {
        get { Mode(rawValue: UserDefaults.standard.string(forKey: "voiceMode") ?? "auto") ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "voiceMode"); apply() }
    }
    private(set) var listening = false
    var onStateChange: (() -> Void)?
    var onWake: (() -> Void)?                 // show HUD
    var onPartial: ((String) -> Void)?        // live text of the question being spoken
    var onQuestion: ((String) -> Void)?       // final question to ask

    // Everything the mic hears is appended to the persistent day log (see Memory).
    func recentTranscript(minutes: Double = 30, maxChars: Int = 2500) -> String { Memory.transcript(hours: minutes / 60, maxChars: maxChars) }

    private let engine = AVAudioEngine()
    private var recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var restartTimer: Timer?, silenceTimer: Timer?
    private var generation = 0   // ignores callbacks from cancelled tasks (prevents restart storms)
    private var lastText = "", lastCommitted = "", capturing = false, captureStart: String.Index? = nil, wakeAt = Date.distantPast
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
        vlog("begin listening=\(listening) available=\(recognizer?.isAvailable == true) onDevice=\(recognizer?.supportsOnDeviceRecognition == true)")
        guard !listening else { return }
        guard let rec = recognizer, rec.isAvailable else {
            // recognizer not ready yet (common right after launch): retry
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in if self?.shouldListen == true { self?.begin() } }
            return
        }
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else { return }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: fmt) { [weak self] buf, _ in self?.request?.append(buf) }
        engine.prepare()
        do { try engine.start() } catch { vlog("audio engine: \(error)"); return }
        listening = true
        newTask()
        onStateChange?()
    }

    func stop() {
        guard listening else { return }
        listening = false; capturing = false
        restartTimer?.invalidate(); silenceTimer?.invalidate()
        task?.cancel(); task = nil; request?.endAudio(); request = nil
        engine.inputNode.removeTap(onBus: 0); engine.stop()
        onStateChange?()
    }

    /// Recognition tasks are limited to ~1 minute; rotate them. Also called after a question is captured.
    private func newTask() {
        task?.cancel(); request?.endAudio()
        let r = SFSpeechAudioBufferRecognitionRequest()
        r.shouldReportPartialResults = true
        if recognizer?.supportsOnDeviceRecognition == true { r.requiresOnDeviceRecognition = true }
        r.taskHint = .dictation
        if #available(macOS 13, *) { r.addsPunctuation = false }
        request = r; lastText = ""; captureStart = nil
        generation += 1; let gen = generation
        task = recognizer?.recognitionTask(with: r) { [weak self] res, err in
            guard let self = self, self.listening, gen == self.generation else { return }
            if let e = err { vlog("task error: \(e)") }
            if let res = res { self.handle(res.bestTranscription.formattedString, final: res.isFinal) }
            if err != nil || res?.isFinal == true {
                // restart shortly (not while a question is mid-capture)
                DispatchQueue.main.asyncAfter(deadline: .now() + (self.capturing ? 0.8 : 0.2)) { if self.listening { self.newTask() } }
            }
        }
        restartTimer?.invalidate()
        restartTimer = Timer.scheduledTimer(withTimeInterval: 50, repeats: false) { [weak self] _ in
            guard let self = self, self.listening, !self.capturing else { return }
            self.commitTranscript(); self.newTask()
        }
    }

    private func commitTranscript() {
        let t = lastText.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty && t != lastCommitted { Memory.log(t); lastCommitted = t }
    }

    private func handle(_ text: String, final: Bool) {
        lastText = text
        let lower = text.lowercased()
        if !capturing {
            // wake word: "jarvis" (tolerate common mis-hearings)
            let wakes = ["jarvis", "jervis", "travis,", "hey travis"]
            if let w = wakes.compactMap({ lower.range(of: $0, options: .backwards) }).first, Date().timeIntervalSince(wakeAt) > 2 {
                wakeAt = Date(); capturing = true; captureStart = w.upperBound
                DispatchQueue.main.async { self.onWake?() }
                armSilence()
            }
        }
        if capturing, let st = captureStart {
            let q = String(text[st...]).trimmingCharacters(in: CharacterSet(charactersIn: " ,.?!"))
            DispatchQueue.main.async { self.onPartial?(q) }
            armSilence()
        }
        if final { commitTranscript() }
    }

    private func armSilence() {
        DispatchQueue.main.async {
            self.silenceTimer?.invalidate()
            self.silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: false) { [weak self] _ in self?.finishCapture() }
        }
    }
    private func finishCapture() {
        guard capturing, let st = captureStart else { return }
        let q = String(lastText[st...]).trimmingCharacters(in: CharacterSet(charactersIn: " ,.?!"))
        capturing = false; captureStart = nil
        commitTranscript()
        if q.split(separator: " ").count >= 2 { onQuestion?(q) }   // ignore a bare "Jarvis"
        newTask()
    }
}
