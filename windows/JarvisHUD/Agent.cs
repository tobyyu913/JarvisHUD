using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace JarvisHUD;

static class Agent {
    public const int MaxSteps = 8;
    public static bool ConfirmActions { get => Settings.GetBool("confirmActions", true); set => Settings.Set("confirmActions", value); }
    public static readonly string[] ToolNames = { "shell", "open", "read_file", "write_file", "search", "telemetry", "clipboard", "recall", "remember", "forget", "disk_scan", "disk_clean", "diagnose", "app_check", "logs", "find_app", "app_vet", "install_app", "app_docs", "malware_scan", "quarantine_item" };
    public const string ToolDoc = """
You are an AGENT on this Windows PC: you can act, not just talk. To use a tool, output a line in exactly this form (one tool per reply, nothing else on that line):
[TOOL:name]{"arg": "value"}
After the tool runs you receive its result and continue. Chain several steps if needed, then give the final answer in plain prose with no tag. Tools:
- shell {"cmd": "...", "timeout": 10}  run a PowerShell command (default 10 s, up to 90). Use for files, apps, system info, winget, git, registry, services, etc. Prefer this for most tasks. The app is NOT elevated: anything needing administrator rights fails with access denied; say what needs admin rights and how to do it instead. For a reminder at a time, create a scheduled task that shows a toast or message: e.g. New-ScheduledTask... or simpler, use the Alarms & Clock app via open "ms-clock:" and tell the user. Windows notifications: New-BurntToastNotification is NOT installed; use msg * "text" for an immediate message box.
- open {"target": "..."}  open an app by name (notepad, calc, "Google Chrome"), a URL, a file path, or a settings page (ms-settings:bluetooth, ms-settings:network-wifi, ms-settings:windowsupdate).
- read_file {"path": "..."}  read a text file (first 8 KB).
- write_file {"path": "...", "content": "..."}  write a text file.
- search {"query": "..."}  web search (only if enabled).
- telemetry {}  fresh CPU/memory/disk/battery/temperature snapshot of this PC.
- clipboard {"text": "..."} put text on the clipboard; {} reads it.
- recall {"query": "keys"} search everything heard (last 14 days) for words; {"hours": 8} returns everything heard in the last N hours instead.
- remember {"note": "keys are in the kitchen drawer"} store a note permanently.
- forget {"note": "keys"} delete remembered notes containing the text.
- disk_scan {}  measure the drive: free space, every cleanable location in three tiers (SAFE / CAN CLEAN BUT SLOWER AFTERWARDS / NEVER), biggest folders and files. Takes up to a minute. ALWAYS run this before proposing or doing any cleaning.
- disk_clean {"items": ["recycle_bin", "temp"]} remove the listed item ids from the scan ({"dry_run": true} to only preview). Only ids from the SAFE and SLOWER tiers are accepted; NEVER-tier items are refused. The app asks the user to confirm.
- diagnose {}  3-second health snapshot: uptime, CPU load, memory and page file, top CPU/memory processes, known background hogs (Windows Search indexer, Defender scan, Windows Update, OneDrive, Delivery Optimization…), disk health and free space, application errors and crashes in the last 24 h, startup apps, network/DNS, battery, pending updates, Defender state.
- app_check {"app": "Name"}  deep check of one app: install path/version/publisher, architecture vs this PC, Authenticode signature, SmartScreen/zone marks, whether it is running, its recent crash/error events, and compatibility notes.
- logs {"process": "Name", "minutes": 10, "filter": "optional text"}  errors and warnings from the Application and System event logs for a process (or any process if omitted).
- find_app {"query": "markdown editor"}  search winget, the Microsoft Store, GitHub releases and the web for apps matching a short query (2-4 words). Returns candidates with source, id, stars/ratings, price and descriptions.
- app_vet {"source": "winget|msstore|github", "id": "..."}  download the real installer and run the security checks (Authenticode signature and publisher, Microsoft Defender scan, VirusTotal hash lookup if a key is set, architecture). Installs nothing. Returns VERDICT: PASS / WARN / FAIL plus details.
- install_app {"source": "...", "id": "..."}  install a vetted app (the app asks the user to confirm). Refuses without a prior app_vet or after FAIL.
- app_docs {"source": "...", "id": "..."}  README / homepage / Store description, to write usage instructions from.
- malware_scan {}  scan this PC for malware (1-2 minutes): Defender / SmartScreen / firewall / UAC state, Defender threat history, startup entries (Run keys, Startup folders, scheduled tasks, non-Microsoft services), running processes (verifiably real ones — Microsoft-signed, Store, valid publisher signature — are skipped), programs running from Temp / AppData / Public / hidden folders, unknown hidden folders, executables disguised as documents, recent downloads, VirusTotal for flagged binaries if a key is set. Returns SUSPICIOUS (act on these) and WORTH A LOOK (usually fine).
- quarantine_item {"path": "..."}  move a suspicious file/program/startup entry into a quarantine folder (kills it, removes its Run-key entry; reversible). The app asks the user to confirm. Refuses verified programs and Windows system paths.
Virus / malware requests: run malware_scan, then report in three short parts: what is clearly fine (counts), what is suspicious and why in plain words, and what is merely unverified. For each suspicious item say what it most likely is (search the web for its name/path if unsure) and offer to quarantine it; quarantine with quarantine_item once the user agrees (one item per call). Never call something a virus without evidence; unsigned ≠ malicious, say "unverified".
Finding and installing apps: when the user describes an app they want, call find_app with a short query (try a second query if the first finds little), then present 3-5 options from the WELL-KNOWN group only, as a numbered list in prose (name, where it comes from, popularity, price, one line on why it fits). Do not show the LESS ESTABLISHED group unless the well-known group is empty or the user turns the well-known ones down; when you do, say plainly that those are smaller, less-proven projects. Then STOP and let the user choose; this is the one time you wait for an answer. Once chosen: app_vet → if PASS, install_app straight away; if WARN, or the vet says VirusTotal is NOT CHECKED for an untrusted download, tell the user in one or two sentences what is off and ask whether to add a VirusTotal key for an antivirus look-up or proceed anyway (never mention VirusTotal for a PASS from a trusted source) → app_docs → then give FULL instructions: how to open it the first time (SmartScreen prompt, permissions it will ask for and why), initial setup, the main features and how to use each, useful shortcuts, where settings live, and how to uninstall. On FAIL, do not install; explain why and offer the next option. Prefer, in order: Microsoft Store (sandboxed) or winget (hash-verified) over raw GitHub downloads.
Troubleshooting: when the user asks why the PC is slow, hot, laggy, frozen, why an app will not open / crashes / hangs, why Wi-Fi or sound or Bluetooth misbehaves, etc.: run diagnose first (app_check for a named app), then dig with shell/logs as needed, and search the web when the local evidence does not explain it (search the exact error text, or the symptom plus the Windows version and PC model). Give the cause in plain words, then FIX IT YOURSELF when the fix is safe and reversible: end a runaway process (Stop-Process), restart Explorer (Stop-Process -Name explorer; Start-Process explorer), restart a user-level service or app, unblock a downloaded file (Unblock-File), clear an app's cache via disk_clean, flush DNS (ipconfig /flushdns), reset the network adapter via ms-settings, re-pair a Bluetooth device, open the right Settings page for the user. For anything that needs administrator rights (sfc /scannow, DISM, chkdsk, driver installs, Windows Update repair, services with admin ACLs), a restart, Safe Mode, or a reset, tell the user exactly what to do and why.
Drive cleaning: when asked to clean, free space or explain what is using the disk, run disk_scan first, then summarise in three short groups with sizes: what is safe to clean, what can be cleaned but makes something slower (say what), and what you will not touch (user data). Propose a concrete list of ids, then call disk_clean with it (the user confirms in the app). Never use shell Remove-Item for cleaning; disk_clean is the only way.
Rules: be decisive, act first, then report briefly. Never ask permission in text; the app confirms destructive commands itself. Never fabricate a tool result. Paths may use ~ or %ENV% variables.
""";

    public static List<string> Ids(JsonObject args) {
        if (args["items"] is JsonArray a) return a.Select(x => x?.ToString() ?? "").Where(x => x.Length > 0).ToList();
        if (args["items"] is JsonValue v && v.GetValueKind() == JsonValueKind.String) return v.GetValue<string>().Split(new[] { ',', ' ' }, StringSplitOptions.RemoveEmptyEntries).ToList();
        return new();
    }
    static string A(JsonObject args, string key, string def = "") => Sys.S(args, key, def);
    static double N(JsonObject args, string key, double def) { try { var v = args[key]; if (v == null) return def; return v.GetValueKind() == JsonValueKind.Number ? v.GetValue<double>() : double.TryParse(v.ToString(), out var d) ? d : def; } catch { return def; } }

    static readonly Regex risky = new(@"\b(Remove-Item|rm |rmdir|del |erase|Format-Volume|format |diskpart|Clear-Disk|Stop-Process|taskkill|Stop-Service|Set-Service|Restart-Computer|Stop-Computer|shutdown|Set-ItemProperty|New-ItemProperty|Remove-ItemProperty|reg add|reg delete|regedit|Unblock-File|netsh|Set-NetAdapter|Disable-NetAdapter|Disable-|Uninstall-|winget uninstall|winget install|Set-ExecutionPolicy|schtasks|Register-ScheduledTask|Add-MpPreference|Set-MpPreference|bcdedit|icacls|takeown|Move-Item|mv |Rename-Item|Out-File|Set-Content|Add-Content|>\s*\S)", RegexOptions.IgnoreCase);
    public static bool NeedsConfirm(string name, JsonObject args) => name switch {
        "shell" => risky.IsMatch(A(args, "cmd")),
        "write_file" or "disk_clean" or "install_app" or "quarantine_item" => name != "disk_clean" || !(args["dry_run"]?.GetValueKind() == JsonValueKind.True),
        _ => false
    };
    public static string Describe(string name, JsonObject args) => name switch {
        "shell" => "Run in PowerShell:\n" + A(args, "cmd"),
        "write_file" => "Write file " + A(args, "path"),
        "disk_clean" => "Clean up:\n" + Cleaner.Describe(Ids(args)),
        "install_app" => "Install " + Installer.DescribeInstall(A(args, "source"), A(args, "id")),
        "quarantine_item" => "Quarantine " + A(args, "path"),
        _ => $"{name} {args.ToJsonString()}"
    };

    public static string Run(string name, JsonObject args) {
        string r;
        try {
            switch (name) {
                case "shell": {
                    var t = Math.Clamp(N(args, "timeout", 10), 1, 90);
                    r = Sys.Ps(A(args, "cmd"), t); if (r.Length == 0) r = "(no output)";
                    break; }
                case "open": {
                    var t = A(args, "target").Trim();
                    var path = Sys.Expand(t);
                    try {
                        if (File.Exists(path) || Directory.Exists(path) || t.Contains("://") || t.StartsWith("ms-")) System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(File.Exists(path) || Directory.Exists(path) ? path : t) { UseShellExecute = true });
                        else {
                            var o = Sys.Ps($"Start-Process -FilePath '{t.Replace("'", "''")}' -ErrorAction Stop; 'ok'", 10);
                            if (!o.Contains("ok")) o = Sys.Ps($"$a = Get-StartApps | Where-Object Name -like '*{t.Replace("'", "''")}*' | Select-Object -First 1; if ($a) {{ Start-Process \"shell:AppsFolder\\$($a.AppID)\"; 'ok' }} else {{ 'not found' }}", 15);
                            if (!o.Contains("ok")) { r = $"Could not open \"{t}\": {o}"; break; }
                        }
                        r = "Opened " + t;
                    } catch (Exception e) { r = $"Could not open \"{t}\": {e.Message}"; }
                    break; }
                case "read_file": {
                    var p = Sys.Expand(A(args, "path"));
                    if (!File.Exists(p)) { r = "No such file: " + p; break; }
                    using var fs = File.OpenRead(p); var buf = new byte[8192]; int nread = fs.Read(buf, 0, buf.Length);
                    r = System.Text.Encoding.UTF8.GetString(buf, 0, nread) + (fs.Length > 8192 ? "\n…(truncated)" : "");
                    break; }
                case "write_file": {
                    var p = Sys.Expand(A(args, "path")); Directory.CreateDirectory(Path.GetDirectoryName(p) ?? ".");
                    File.WriteAllText(p, A(args, "content")); r = "Wrote " + p; break; }
                case "search": r = Search.Enabled ? Search.Run(A(args, "query")).GetAwaiter().GetResult() : "search is not configured"; break;
                case "telemetry": r = Stats.Summary(true); break;
                case "clipboard": {
                    var t = A(args, "text"); string outp = "";
                    var th = new Thread(() => { try { if (t.Length > 0) { System.Windows.Clipboard.SetText(t); outp = "Copied to clipboard."; } else outp = System.Windows.Clipboard.ContainsText() ? System.Windows.Clipboard.GetText() : "(clipboard has no text)"; } catch (Exception e) { outp = "Clipboard error: " + e.Message; } });
                    th.SetApartmentState(ApartmentState.STA); th.Start(); th.Join(); r = outp; break; }
                case "recall": {
                    var q = A(args, "query"); var h = N(args, "hours", 0);
                    r = q.Length > 0 ? Memory.Search(q) : Memory.Transcript(h > 0 ? h : 24); if (r.Length == 0) r = "(nothing heard in that period)"; break; }
                case "remember": r = Memory.Remember(A(args, "note", A(args, "text"))); break;
                case "forget": r = Memory.ForgetNote(A(args, "note", A(args, "text"))); break;
                case "disk_scan": r = Cleaner.Scan(s => OnScanStatus?.Invoke(s)).Report(); break;
                case "disk_clean": r = Cleaner.Clean(Ids(args), args["dry_run"]?.GetValueKind() == JsonValueKind.True); break;
                case "diagnose": r = Doctor.Diagnose(); break;
                case "app_check": r = Doctor.AppCheck(A(args, "app", A(args, "name"))); break;
                case "logs": r = Doctor.Logs(A(args, "process"), (int)N(args, "minutes", 10), A(args, "filter")); break;
                case "find_app": r = Installer.Find(A(args, "query")).GetAwaiter().GetResult(); break;
                case "app_vet": r = Installer.Vet(A(args, "source"), A(args, "id")).GetAwaiter().GetResult(); break;
                case "install_app": r = Installer.Install(A(args, "source"), A(args, "id")); break;
                case "app_docs": r = Installer.Docs(A(args, "source"), A(args, "id")).GetAwaiter().GetResult(); break;
                case "malware_scan": r = Guard.Scan(s => OnScanStatus?.Invoke(s)); break;
                case "quarantine_item": r = Guard.Quarantine(A(args, "path")); break;
                default: r = $"unknown tool {name}. Available: {string.Join(", ", ToolNames)}. Use exactly [TOOL:name]{{json}} and nothing else on that line."; break;
            }
        } catch (Exception e) { r = $"Tool {name} failed: {e.Message}"; }
        if (r.Length > 12000) r = r[..12000] + "\n…(truncated)";
        Log.V($"tool {name} → {r[..Math.Min(200, r.Length)].Replace('\n', ' ')}");
        return r;
    }
    public static Action<string>? OnScanStatus;

    /// Tolerant parser: "[TOOL: Remember]", "[tool:open-url]", fenced JSON, first balanced {...}.
    public static (string name, JsonObject args, int index)? Parse(string r) {
        var m = Regex.Match(r, @"\[TOOL:\s*([A-Za-z_\-]+)\s*\]", RegexOptions.IgnoreCase);
        if (!m.Success) return null;
        var name = m.Groups[1].Value.Trim().ToLowerInvariant().Replace('-', '_');
        var rest = r[(m.Index + m.Length)..].Trim();
        if (rest.StartsWith("```")) rest = Regex.Replace(rest, @"^```\w*\n?", "");
        int depth = 0, end = -1; bool inStr = false, esc = false;
        for (int i = 0; i < rest.Length; i++) {
            char ch = rest[i];
            if (inStr) { if (esc) esc = false; else if (ch == '\\') esc = true; else if (ch == '"') inStr = false; continue; }
            if (ch == '"') inStr = true; else if (ch == '{') depth++; else if (ch == '}') { depth--; if (depth == 0) { end = i; break; } }
        }
        var args = new JsonObject();
        int st = rest.IndexOf('{');
        if (end >= 0 && st >= 0 && st < end) { try { args = JsonNode.Parse(rest[st..(end + 1)]) as JsonObject ?? new JsonObject(); } catch { } }
        return (name, args, m.Index);
    }
}
