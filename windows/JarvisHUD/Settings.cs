using System.Text.Json;
using System.Text.Json.Nodes;

namespace JarvisHUD;

/// Persistent settings (%APPDATA%\JarvisHUD\settings.json) and the file debug log.
static class Settings {
    public static readonly string Dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "JarvisHUD");
    static readonly string File_ = Path.Combine(Dir, "settings.json");
    static JsonObject obj = Load();
    static readonly object lock_ = new();
    static JsonObject Load() {
        try { Directory.CreateDirectory(Dir); if (File.Exists(File_)) return JsonNode.Parse(File.ReadAllText(File_)) as JsonObject ?? new JsonObject(); } catch { }
        return new JsonObject();
    }
    public static string Get(string key, string def = "") { lock (lock_) return obj[key]?.GetValue<string>() ?? def; }
    public static bool GetBool(string key, bool def = false) { lock (lock_) { var v = obj[key]; return v == null ? def : v.GetValueKind() == JsonValueKind.True || (v.GetValueKind() == JsonValueKind.String && v.GetValue<string>() == "true"); } }
    public static bool Has(string key) { lock (lock_) return obj.ContainsKey(key); }
    public static void Set(string key, string value) { lock (lock_) { obj[key] = value; Save(); } }
    public static void Set(string key, bool value) { lock (lock_) { obj[key] = value; Save(); } }
    public static void Remove(string key) { lock (lock_) { obj.Remove(key); Save(); } }
    static void Save() { try { File.WriteAllText(File_, obj.ToJsonString(new JsonSerializerOptions { WriteIndented = true })); } catch { } }
}

static class Log {
    static readonly string file = Path.Combine(Settings.Dir, "debug.log");
    static readonly object lock_ = new();
    public static void V(string s) {
        try { lock (lock_) {
            var fi = new FileInfo(file); if (fi.Exists && fi.Length > 2_000_000) fi.Delete();
            File.AppendAllText(file, $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {s}\n");
        } } catch { }
    }
}

/// Small helpers shared by every tool: run PowerShell, run a program, HTTP.
static class Sys {
    public static readonly string Home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    public static readonly HttpClient Http = new(new HttpClientHandler { AutomaticDecompression = System.Net.DecompressionMethods.All }) { Timeout = TimeSpan.FromSeconds(60) };
    static Sys() { Http.DefaultRequestHeaders.UserAgent.ParseAdd("JarvisHUD/1.8 (Windows)"); }

    /// Run a PowerShell snippet, capture stdout+stderr, kill after timeout seconds.
    public static string Ps(string script, double timeout = 15) {
        var enc = Convert.ToBase64String(System.Text.Encoding.Unicode.GetBytes(script));
        return Run("powershell.exe", $"-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand {enc}", timeout);
    }
    public static string Run(string exe, string args, double timeout = 15, string? cwd = null) {
        try {
            var p = new System.Diagnostics.Process { StartInfo = new System.Diagnostics.ProcessStartInfo(exe, args) {
                RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true,
                StandardOutputEncoding = System.Text.Encoding.UTF8, StandardErrorEncoding = System.Text.Encoding.UTF8, WorkingDirectory = cwd ?? Home } };
            var sb = new System.Text.StringBuilder(); var lk = new object();
            p.OutputDataReceived += (_, e) => { if (e.Data != null) lock (lk) sb.AppendLine(e.Data); };
            p.ErrorDataReceived += (_, e) => { if (e.Data != null) lock (lk) sb.AppendLine(e.Data); };
            p.Start(); p.BeginOutputReadLine(); p.BeginErrorReadLine();
            if (!p.WaitForExit((int)(timeout * 1000))) { try { p.Kill(true); } catch { } lock (lk) sb.AppendLine($"(timed out after {timeout:0} s)"); }
            else p.WaitForExit();
            lock (lk) return sb.ToString().Trim();
        } catch (Exception e) { return $"(could not run {exe}: {e.Message})"; }
    }
    public static string Expand(string p) {
        p = p.Trim().Trim('"');
        if (p.StartsWith("~")) p = Home + p[1..];
        return Environment.ExpandEnvironmentVariables(p).Replace('/', '\\');
    }
    public static string Human(long bytes) {
        double b = bytes; string[] u = { "B", "KB", "MB", "GB", "TB" }; int i = 0;
        while (b >= 1024 && i < u.Length - 1) { b /= 1024; i++; }
        return i == 0 ? $"{b:0} B" : $"{b:0.#} {u[i]}";
    }
    public static async Task<string> GetAsync(string url, Dictionary<string, string>? headers = null, double timeout = 20) {
        using var req = new HttpRequestMessage(HttpMethod.Get, url);
        if (headers != null) foreach (var h in headers) req.Headers.TryAddWithoutValidation(h.Key, h.Value);
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(timeout));
        using var r = await Http.SendAsync(req, cts.Token);
        return await r.Content.ReadAsStringAsync(cts.Token);
    }
    public static async Task<(int status, string body)> PostJsonAsync(string url, object body, Dictionary<string, string>? headers = null, double timeout = 60) {
        using var req = new HttpRequestMessage(HttpMethod.Post, url) { Content = new StringContent(JsonSerializer.Serialize(body), System.Text.Encoding.UTF8, "application/json") };
        if (headers != null) foreach (var h in headers) req.Headers.TryAddWithoutValidation(h.Key, h.Value);
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(timeout));
        using var r = await Http.SendAsync(req, cts.Token);
        return ((int)r.StatusCode, await r.Content.ReadAsStringAsync(cts.Token));
    }
    public static JsonNode? J(string s) { try { return JsonNode.Parse(s); } catch { return null; } }
    public static string S(JsonNode? n, string key, string def = "") { try { var v = n?[key]; return v == null ? def : v.GetValueKind() == JsonValueKind.String ? v.GetValue<string>() : v.ToJsonString(); } catch { return def; } }
}
