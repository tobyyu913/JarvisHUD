using System.Text.Json;
using System.Text.Json.Nodes;

namespace JarvisHUD;

/// All-day log of everything heard (kept 14 days), explicit notes ("remember that…") and the chat history.
/// Everything lives in %APPDATA%\JarvisHUD.
static class Memory {
    public const int KeepDays = 14;
    public static readonly string Dir = Settings.Dir;
    static readonly string Heard = Path.Combine(Dir, "heard");
    static readonly object lock_ = new();
    static Memory() { Directory.CreateDirectory(Heard); }

    static string File_(DateTime d) => Path.Combine(Heard, d.ToString("yyyy-MM-dd") + ".log");
    public static void LogHeard(string text) {
        var t = text.Trim(); if (t.Length == 0) return;
        lock (lock_) { try { File.AppendAllText(File_(DateTime.Now), $"[{DateTime.Now:yyyy-MM-dd HH:mm}] {t}\n"); } catch { } }
    }
    public static string Transcript(double hours, int maxChars = 4000) {
        var cutoff = DateTime.Now.AddHours(-hours); var outp = new List<string>();
        for (int d = 0; d <= (int)(hours / 24) + 1; d++) {
            var f = File_(DateTime.Now.AddDays(-d)); if (!File.Exists(f)) continue;
            foreach (var l in File.ReadAllLines(f)) {
                if (l.Length < 18) continue;
                if (DateTime.TryParseExact(l.Substring(1, 16), "yyyy-MM-dd HH:mm", null, System.Globalization.DateTimeStyles.None, out var t) && t >= cutoff) outp.Add(l);
            }
        }
        outp.Sort(); var s = string.Join("\n", outp);
        return s.Length > maxChars ? "…" + s[^maxChars..] : s;
    }
    public static string Search(string query, int maxLines = 40) {
        var words = query.ToLowerInvariant().Split(' ', StringSplitOptions.RemoveEmptyEntries).Where(w => w.Length > 2).ToList();
        if (words.Count == 0) return Transcript(24);
        var hits = new List<string>();
        foreach (var f in Directory.GetFiles(Heard, "*.log").OrderByDescending(x => x)) {
            foreach (var l in File.ReadAllLines(f).Reverse()) {
                var low = l.ToLowerInvariant();
                if (words.Any(low.Contains)) { hits.Add(l); if (hits.Count >= maxLines) { hits.Reverse(); return string.Join("\n", hits); } }
            }
        }
        if (hits.Count == 0) return $"(nothing heard matching: {query})";
        hits.Reverse(); return string.Join("\n", hits);
    }
    public static void ForgetToday() { try { File.Delete(File_(DateTime.Now)); } catch { } }
    public static void ForgetAllHeard() { try { Directory.Delete(Heard, true); } catch { } Directory.CreateDirectory(Heard); }
    public static void Prune() {
        var cutoff = DateTime.Now.AddDays(-KeepDays).ToString("yyyy-MM-dd");
        foreach (var f in Directory.GetFiles(Heard, "*.log")) if (string.CompareOrdinal(Path.GetFileNameWithoutExtension(f), cutoff) < 0) { try { File.Delete(f); } catch { } }
    }

    // notes
    static string NotesFile => Path.Combine(Dir, "notes.json");
    public static List<Dictionary<string, string>> Notes {
        get { try { return JsonSerializer.Deserialize<List<Dictionary<string, string>>>(File.ReadAllText(NotesFile)) ?? new(); } catch { return new(); } }
        set { try { File.WriteAllText(NotesFile, JsonSerializer.Serialize(value, new JsonSerializerOptions { WriteIndented = true })); } catch { } }
    }
    public static string Remember(string note) {
        var n = Notes; n.Add(new() { ["when"] = DateTime.Now.ToString("yyyy-MM-dd HH:mm"), ["note"] = note.Trim() }); Notes = n;
        return $"Noted ({n.Count} notes kept).";
    }
    public static string ForgetNote(string text) {
        var n = Notes; int before = n.Count;
        n.RemoveAll(x => (x.GetValueOrDefault("note") ?? "").Contains(text, StringComparison.OrdinalIgnoreCase)); Notes = n;
        return before == n.Count ? $"No note matched \"{text}\"." : $"Forgot {before - n.Count} note(s).";
    }
    public static void ForgetAllNotes() => Notes = new();
    public static string NotesText => string.Join("\n", Notes.Select(x => $"[{x.GetValueOrDefault("when")}] {x.GetValueOrDefault("note")}"));

    // chat history (last 60 turns, survives restarts)
    static string HistoryFile => Path.Combine(Dir, "history.json");
    public static List<(string role, string text)> LoadHistory() {
        try {
            var arr = JsonNode.Parse(File.ReadAllText(HistoryFile)) as JsonArray;
            return arr?.Select(x => (Sys.S(x, "role"), Sys.S(x, "text"))).Where(x => x.Item1.Length > 0).ToList() ?? new();
        } catch { return new(); }
    }
    public static void SaveHistory(List<(string role, string text)> h) {
        try {
            var arr = new JsonArray(h.Select(x => (JsonNode)new JsonObject { ["role"] = x.role, ["text"] = x.text }).ToArray());
            File.WriteAllText(HistoryFile, arr.ToJsonString());
        } catch { }
    }
}
