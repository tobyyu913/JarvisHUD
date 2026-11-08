using System.Globalization;
using System.Speech.Recognition;

namespace JarvisHUD;

/// Always-on wake-word listener using Windows' offline speech recognition (System.Speech), one engine per
/// installed recognizer language. Everything heard is logged to Memory; "Jarvis, …" becomes a command.
sealed class Voice {
    public static readonly Voice Shared = new();
    public static readonly (string id, string name, string[] wakes)[] Languages = {
        ("en-US", "English", new[] { "jarvis", "hey jarvis", "travis" }), ("en-GB", "English (UK)", new[] { "jarvis", "hey jarvis" }),
        ("zh-CN", "中文（简体）", new[] { "贾维斯", "加维斯", "贾维思", "家维斯" }), ("zh-TW", "中文（繁體）", new[] { "賈維斯", "加維斯" }), ("zh-HK", "粵語", new[] { "賈維斯" }),
        ("ja-JP", "日本語", new[] { "ジャービス", "ジャーヴィス" }), ("ko-KR", "한국어", new[] { "자비스" }),
        ("es-ES", "Español", new[] { "jarvis" }), ("fr-FR", "Français", new[] { "jarvis" }), ("de-DE", "Deutsch", new[] { "jarvis" }), ("it-IT", "Italiano", new[] { "jarvis" }), ("pt-BR", "Português", new[] { "jarvis" }),
        ("ru-RU", "Русский", new[] { "джарвис" }), ("hi-IN", "हिन्दी", new[] { "jarvis", "जार्विस" }), ("ar-SA", "العربية", new[] { "جارفيس" }),
    };
    public Action<string>? OnCommand;     // spoken request after the wake word
    public Action<string>? OnState;       // LISTENING / HEARD …
    readonly List<SpeechRecognitionEngine> engines = new();
    readonly object lock_ = new();
    bool capturing; DateTime wakeAt = DateTime.MinValue; string captureLang = "";
    System.Threading.Timer? captureTimer; string captured = "";

    public static bool Enabled { get => Settings.GetBool("voiceOn", false); set => Settings.Set("voiceOn", value); }
    public static List<string> Installed => SpeechRecognitionEngine.InstalledRecognizers().Select(r => r.Culture.Name).Distinct().ToList();
    public static List<string> Selected {
        get { var s = Settings.Get("voiceLocales"); if (s.Length > 0) return s.Split(',').ToList(); var inst = Installed; return inst.Count > 0 ? new List<string> { inst[0] } : new(); }
        set => Settings.Set("voiceLocales", string.Join(",", value));
    }
    public bool Running { get { lock (lock_) return engines.Count > 0; } }

    public string Start() {
        Stop();
        var inst = SpeechRecognitionEngine.InstalledRecognizers();
        if (inst.Count == 0) return "Windows has no speech recognition language installed. Settings → Time & language → Speech → add a language with speech recognition, then try again.";
        var wanted = Selected; var started = new List<string>();
        foreach (var ri in inst) {
            if (!wanted.Contains(ri.Culture.Name)) continue;
            try {
                var e = new SpeechRecognitionEngine(ri);
                e.LoadGrammar(new DictationGrammar());
                var wakes = Languages.FirstOrDefault(l => l.id == ri.Culture.Name).wakes ?? new[] { "jarvis" };
                try { var g = new Grammar(new GrammarBuilder(new Choices(wakes)) { Culture = ri.Culture }) { Name = "wake", Priority = 10 }; e.LoadGrammar(g); } catch { }
                e.SetInputToDefaultAudioDevice();
                e.SpeechRecognized += (_, ev) => Handle(ev.Result.Text, ev.Result.Confidence, ri.Culture.Name);
                e.RecognizeCompleted += (_, ev) => { if (ev.Error != null) Log.V("speech error " + ev.Error.Message); };
                e.RecognizeAsync(RecognizeMode.Multiple);
                lock (lock_) engines.Add(e); started.Add(ri.Culture.Name);
            } catch (Exception ex) { Log.V($"speech {ri.Culture.Name}: {ex.Message}"); if (ex.Message.Contains("audio", StringComparison.OrdinalIgnoreCase)) return "No microphone available (or microphone access is off in Settings → Privacy → Microphone)."; }
        }
        if (started.Count == 0) return "None of the selected languages has a Windows speech recognizer installed. Installed: " + string.Join(", ", inst.Select(r => r.Culture.Name));
        OnState?.Invoke("LISTENING"); Log.V("voice started: " + string.Join(",", started));
        return "";
    }
    public void Stop() { lock (lock_) { foreach (var e in engines) { try { e.RecognizeAsyncCancel(); e.Dispose(); } catch { } } engines.Clear(); } }

    void Handle(string text, float conf, string lang) {
        text = text.Trim(); if (text.Length == 0) return;
        Log.V($"heard[{lang} {conf:0.00}] {text}");
        if (conf < 0.3) return;
        Memory.LogHeard(text);
        var wakes = Languages.FirstOrDefault(l => l.id == lang).wakes ?? new[] { "jarvis" };
        var low = text.ToLowerInvariant();
        int idx = -1, wlen = 0;
        foreach (var w in wakes) { var i = low.LastIndexOf(w, StringComparison.OrdinalIgnoreCase); if (i > idx) { idx = i; wlen = w.Length; } }
        lock (lock_) {
            if (idx >= 0 && (DateTime.Now - wakeAt).TotalSeconds > 2) {
                wakeAt = DateTime.Now; capturing = true; captureLang = lang; captured = text[(idx + wlen)..].Trim(new[] { ' ', ',', '，', '、', '。', '.' });
                OnState?.Invoke("HEARD WAKE WORD");
                ArmCapture(captured.Length >= 3 ? 1.2 : 5.0);
                return;
            }
            if (capturing && lang == captureLang) { captured = (captured + " " + text).Trim(); ArmCapture(1.4); }
        }
    }
    void ArmCapture(double seconds) {
        captureTimer?.Dispose();
        captureTimer = new System.Threading.Timer(_ => {
            string q; lock (lock_) { q = captured; capturing = false; captured = ""; }
            if (q.Length >= 2) { OnState?.Invoke("LISTENING"); OnCommand?.Invoke(q); } else OnState?.Invoke("LISTENING");
        }, null, TimeSpan.FromSeconds(seconds), Timeout.InfiniteTimeSpan);
    }
}
