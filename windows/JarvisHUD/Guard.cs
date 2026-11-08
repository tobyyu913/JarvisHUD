using System.Security.Cryptography;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace JarvisHUD;

/// Security guard: trust classification of programs, a whole-PC malware sweep, a quarantine folder,
/// and a watcher that vets every new download.
static class Guard {
    public static string VtKey { get => Settings.Get("vtKey"); set => Settings.Set("vtKey", value); }
    public static readonly string QuarantineDir = Path.Combine(Settings.Dir, "quarantine");

    public record Trust(string Level, string Signer);   // microsoft | valid | store | unsigned | invalid
    static readonly Dictionary<string, Trust> trustCache = new(StringComparer.OrdinalIgnoreCase);
    public static Trust TrustOf(string path) {
        lock (trustCache) if (trustCache.TryGetValue(path, out var t)) return t;
        var r = Sys.Ps($"$s=Get-AuthenticodeSignature -LiteralPath '{path.Replace("'", "''")}' -ErrorAction SilentlyContinue; if ($s) {{ $s.Status.ToString() + '|' + $(if ($s.SignerCertificate) {{ $s.SignerCertificate.Subject }} else {{ '' }}) + '|' + $s.StatusMessage }}", 20);
        var parts = r.Split('|'); var status = parts.Length > 0 ? parts[0] : "";
        var signer = parts.Length > 1 ? Regex.Match(parts[1], @"CN=([^,]+)").Groups[1].Value.Trim('"') : "";
        Trust t2;
        if (status == "Valid" && Regex.IsMatch(signer, @"^Microsoft (Corporation|Windows)", RegexOptions.IgnoreCase)) t2 = new("microsoft", signer);
        else if (status == "Valid") t2 = new("valid", signer);
        else if (path.Contains(@"\WindowsApps\", StringComparison.OrdinalIgnoreCase)) t2 = new("store", "Microsoft Store");
        else if (status == "NotSigned" || status == "") t2 = new("unsigned", "");
        else t2 = new("invalid", $"{status} {signer}".Trim());
        lock (trustCache) trustCache[path] = t2;
        return t2;
    }
    public static bool OddLocation(string p) => Regex.IsMatch(p, @"\\(Temp|Tmp|AppData\\Local\\Temp|Public|ProgramData\\[^\\]+\\[^\\]+\.exe$|Users\\[^\\]+\\(Downloads|Documents|Pictures|Music|Videos)\\|Recycle|\$Recycle\.Bin|Windows\\Temp|Users\\Public)", RegexOptions.IgnoreCase) || Regex.IsMatch(p, @"\\\.[^\\]+\\", RegexOptions.None);
    public static bool LooksLikeWindows(string name) => Regex.IsMatch(name, @"^(svchost|csrss|lsass|winlogon|explorer|services|smss|wininit|dwm|taskhostw|RuntimeBroker|conhost|spoolsv|SearchIndexer|MsMpEng|ctfmon|sihost|fontdrvhost|dllhost|WmiPrvSE|SecurityHealth\w*|OneDrive|msedge|chrome)\.exe$", RegexOptions.IgnoreCase);

    public static string Sha256(string path) { using var s = File.OpenRead(path); return Convert.ToHexString(SHA256.HashData(s)).ToLowerInvariant(); }
    public static async Task<string> VirusTotal(string path) {
        if (VtKey.Length == 0) return "NOT CHECKED (no VirusTotal key set; tray menu → VirusTotal Key…)";
        try {
            var h = Sha256(path);
            using var req = new HttpRequestMessage(HttpMethod.Get, "https://www.virustotal.com/api/v3/files/" + h); req.Headers.Add("x-apikey", VtKey);
            using var r = await Sys.Http.SendAsync(req);
            if ((int)r.StatusCode == 404) return "unknown to VirusTotal (never submitted); treat as unverified";
            var j = Sys.J(await r.Content.ReadAsStringAsync());
            var st = j?["data"]?["attributes"]?["last_analysis_stats"];
            if (st == null) return "VirusTotal error: " + Sys.S(j?["error"], "message", r.StatusCode.ToString());
            int mal = (int)(st["malicious"]?.GetValue<double>() ?? 0), sus = (int)(st["suspicious"]?.GetValue<double>() ?? 0), ok = (int)(st["harmless"]?.GetValue<double>() ?? 0) + (int)(st["undetected"]?.GetValue<double>() ?? 0);
            return $"{mal} malicious, {sus} suspicious, {ok} clean of {mal + sus + ok} engines";
        } catch (Exception e) { return "VirusTotal error: " + e.Message; }
    }
    public static string DefenderScan(string path) {
        var exe = Directory.Exists(@"C:\Program Files\Windows Defender") ? Directory.GetFiles(@"C:\Program Files\Windows Defender", "MpCmdRun.exe", SearchOption.AllDirectories).FirstOrDefault() : null;
        exe ??= Directory.Exists(@"C:\ProgramData\Microsoft\Windows Defender\Platform") ? Directory.GetFiles(@"C:\ProgramData\Microsoft\Windows Defender\Platform", "MpCmdRun.exe", SearchOption.AllDirectories).OrderByDescending(x => x).FirstOrDefault() : null;
        if (exe == null) return "Microsoft Defender command-line scanner not found";
        var o = Sys.Run(exe, $"-Scan -ScanType 3 -File \"{path}\" -DisableRemediation", 120);
        if (o.Contains("found no threats", StringComparison.OrdinalIgnoreCase)) return "Defender: clean";
        if (o.Contains("Threat", StringComparison.OrdinalIgnoreCase)) return "Defender: THREAT DETECTED\n" + string.Join("\n", o.Split('\n').Where(l => l.Contains("Threat", StringComparison.OrdinalIgnoreCase)).Take(5));
        return "Defender: " + (o.Length > 300 ? o[^300..] : o);
    }

    /// Inspect one downloaded file (installer, archive, script). verdict PASS/WARN/FAIL.
    public static (string verdict, string detail) Inspect(string file, bool suspiciousSource = false) {
        var lines = new List<string>(); int bad = 0, warn = 0;
        var fi = new FileInfo(file); var ext = fi.Extension.ToLowerInvariant();
        lines.Add($"File: {fi.Name} ({Sys.Human(fi.Length)})");
        if (Regex.IsMatch(fi.Name, @"\.(pdf|docx?|xlsx?|jpe?g|png|txt|mp[34])\.(exe|scr|bat|cmd|js|vbs|ps1|lnk)$", RegexOptions.IgnoreCase)) { bad++; lines.Add("Program DISGUISED as a document (double extension)"); }
        var targets = new List<string>();
        if (ext == ".zip" || ext == ".7z" || ext == ".rar") {
            var dir = Path.Combine(Settings.Dir, "downloads", "x-" + Guid.NewGuid().ToString("N")[..8]); Directory.CreateDirectory(dir);
            try { if (ext == ".zip") System.IO.Compression.ZipFile.ExtractToDirectory(file, dir, true); else Sys.Ps($"if (Get-Command 7z -ErrorAction SilentlyContinue) {{ 7z x -y -o'{dir}' '{file}' | Out-Null }}", 60); } catch (Exception e) { lines.Add("archive could not be opened: " + e.Message); }
            var all = Directory.EnumerateFiles(dir, "*", SearchOption.AllDirectories).ToList();
            var execs = all.Where(f => Regex.IsMatch(f, @"\.(exe|msi|dll|scr|bat|cmd|ps1|vbs|js|jar|lnk)$", RegexOptions.IgnoreCase)).ToList();
            lines.Add($"Archive: {all.Count} files, {execs.Count} executable");
            if (execs.Any(f => Regex.IsMatch(f, @"\.(bat|cmd|vbs|js|lnk|scr)$", RegexOptions.IgnoreCase))) { warn++; lines.Add("contains scripts/shortcuts (.bat/.cmd/.vbs/.js/.lnk/.scr): common malware carriers"); }
            targets.AddRange(execs.Where(f => Regex.IsMatch(f, @"\.(exe|msi|dll)$", RegexOptions.IgnoreCase)).Take(6));
        } else if (Regex.IsMatch(ext, @"^\.(exe|msi|msix|appx|dll|scr|com)$")) targets.Add(file);
        else if (Regex.IsMatch(ext, @"^\.(bat|cmd|ps1|vbs|js|lnk|hta|iso|img)$")) { warn++; lines.Add($"{ext} files are a common malware vehicle; only run if you expected exactly this"); if (ext == ".ps1") lines.Add("Script head: " + string.Join(" | ", File.ReadLines(file).Take(5))); }
        else lines.Add("Not a program; nothing to execute");
        foreach (var t in targets) {
            var tr = TrustOf(t);
            var tag = tr.Level switch { "microsoft" => "signed by Microsoft", "valid" => $"validly signed by {tr.Signer}", "store" => "Microsoft Store package", "unsigned" => "NOT SIGNED (unverified publisher)", _ => $"INVALID signature: {tr.Signer}" };
            if (tr.Level == "invalid") bad++; else if (tr.Level == "unsigned") warn++;
            lines.Add($"{Path.GetFileName(t)}: {tag}");
        }
        var scanTarget = targets.FirstOrDefault() ?? file;
        var def = DefenderScan(scanTarget); lines.Add(def); if (def.Contains("THREAT")) bad += 2;
        bool wantVt = suspiciousSource || warn > 0 || bad > 0;
        if (wantVt) {
            var vt = VirusTotal(scanTarget).GetAwaiter().GetResult(); lines.Add("VirusTotal: " + vt);
            var m = Regex.Match(vt, @"^(\d+) malicious, (\d+) suspicious"); if (m.Success) { int mal = int.Parse(m.Groups[1].Value); if (mal >= 3) bad += 2; else if (mal + int.Parse(m.Groups[2].Value) > 0) warn++; }
        }
        var verdict = bad > 0 ? "FAIL" : warn > 0 ? "WARN" : "PASS";
        return (verdict, "VERDICT: " + verdict + "\n" + string.Join("\n", lines));
    }

    public static string Scan(Action<string>? status = null) {
        status?.Invoke("SCANNING FOR MALWARE");
        var sus = new List<string>(); var look = new List<string>(); var info = new List<string>();
        var state = Sys.Ps("try { $d=Get-MpComputerStatus; 'Defender realtime=' + $d.RealTimeProtectionEnabled + ' antivirus=' + $d.AntivirusEnabled + ' signatures=' + $d.AntivirusSignatureLastUpdated.ToString('yyyy-MM-dd') + ' lastQuickScan=' + $d.QuickScanEndTime } catch { 'Defender status unavailable (third-party antivirus?)' }; $ss=(Get-ItemProperty 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer' -ErrorAction SilentlyContinue).SmartScreenEnabled; 'SmartScreen=' + $(if ($ss) { $ss } else { 'default (on)' }); $fw=Get-NetFirewallProfile -ErrorAction SilentlyContinue | ForEach-Object { \"$($_.Name)=$($_.Enabled)\" }; 'Firewall: ' + ($fw -join ' '); $uac=(Get-ItemProperty 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System').EnableLUA; 'UAC=' + $(if ($uac -eq 1) { 'on' } else { 'OFF' })", 30);
        info.Add(state);
        if (state.Contains("realtime=False")) sus.Add("Defender real-time protection is OFF (malware often disables it first; or a third-party antivirus replaced it)");
        if (state.Contains("UAC=OFF")) sus.Add("UAC is disabled: any program can gain admin silently");
        var threats = Sys.Ps("try { Get-MpThreatDetection -ErrorAction Stop | Sort-Object InitialDetectionTime -Descending | Select-Object -First 8 | ForEach-Object { $t=Get-MpThreat -ThreatID $_.ThreatID -ErrorAction SilentlyContinue; \"{0:yyyy-MM-dd} {1} [{2}] {3}\" -f $_.InitialDetectionTime,$t.ThreatName,$_.ActionSuccess,($_.Resources -join ', ') } } catch { '' }; try { $ex=Get-MpPreference; if ($ex.ExclusionPath) { 'Defender EXCLUSIONS: ' + ($ex.ExclusionPath -join '; ') } } catch {}", 30);
        if (threats.Length > 0) { if (threats.Contains("EXCLUSIONS")) sus.Add("Defender has folder exclusions (malware adds its own folder here): " + threats.Split('\n').First(l => l.Contains("EXCLUSIONS"))); info.Add("Defender history:\n" + threats); }
        status?.Invoke("CHECKING STARTUP");
        // startup: Run keys, Startup folders, scheduled tasks, services
        var startup = Sys.Ps(@"
foreach ($k in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run','HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce','HKLM:\Software\Microsoft\Windows\CurrentVersion\Run','HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run') {
  $p = Get-ItemProperty $k -ErrorAction SilentlyContinue; if ($p) { $p.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object { 'RUN|' + $k + '|' + $_.Name + '|' + $_.Value } }
}
Get-ChildItem ([Environment]::GetFolderPath('Startup')),([Environment]::GetFolderPath('CommonStartup')) -ErrorAction SilentlyContinue | ForEach-Object { 'STARTUP|' + $_.FullName + '|' + $(if ($_.Extension -eq '.lnk') { (New-Object -ComObject WScript.Shell).CreateShortcut($_.FullName).TargetPath } else { $_.FullName }) }
Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskPath -notlike '\Microsoft\*' -and $_.State -ne 'Disabled' } | ForEach-Object { $a=$_.Actions | Select-Object -First 1; 'TASK|' + $_.TaskPath + $_.TaskName + '|' + $a.Execute + ' ' + $a.Arguments }
Get-CimInstance Win32_Service | Where-Object { $_.PathName -and $_.PathName -notmatch '\\Windows\\' -and $_.StartMode -eq 'Auto' } | ForEach-Object { 'SERVICE|' + $_.Name + '|' + $_.PathName }
$w = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction SilentlyContinue; if ($w.Shell -and $w.Shell -ne 'explorer.exe') { 'WINLOGON|Shell|' + $w.Shell }; if ($w.Userinit -and $w.Userinit -notmatch '^C:\\Windows\\system32\\userinit\.exe,?$') { 'WINLOGON|Userinit|' + $w.Userinit }
$ifeo = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options' -ErrorAction SilentlyContinue | Where-Object { (Get-ItemProperty $_.PSPath).Debugger } | ForEach-Object { 'IFEO|' + $_.PSChildName + '|' + (Get-ItemProperty $_.PSPath).Debugger }; if ($ifeo) { $ifeo }
$hosts = Get-Content C:\Windows\System32\drivers\etc\hosts -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\s*\d' -and $_ -notmatch 'localhost' }; if ($hosts) { 'HOSTS|' + ($hosts -join '; ') }
", 60);
        int fine = 0;
        foreach (var l in startup.Split('\n', StringSplitOptions.RemoveEmptyEntries)) {
            var p = l.Split('|'); if (p.Length < 3) continue;
            var kind = p[0]; var cmdline = p[^1].Trim();
            if (kind == "WINLOGON" || kind == "IFEO") { sus.Add($"{kind} hijack: {p[1]} = {cmdline}"); continue; }
            if (kind == "HOSTS") { look.Add("hosts file has custom entries: " + cmdline[..Math.Min(200, cmdline.Length)]); continue; }
            var exe = ExeFrom(cmdline); if (exe == null || !File.Exists(exe)) { if (cmdline.Length > 0 && (kind == "RUN" || kind == "STARTUP")) look.Add($"{kind} entry points to a missing file: {p[^2]} → {cmdline[..Math.Min(120, cmdline.Length)]}"); continue; }
            var tr = TrustOf(exe);
            if (tr.Level is "microsoft" or "store") { fine++; continue; }
            if (tr.Level == "valid" && !OddLocation(exe)) { fine++; continue; }
            var desc = $"{kind} {p[1 % p.Length]}: {exe}";
            if (Regex.IsMatch(cmdline, @"powershell|wscript|cscript|mshta|rundll32|regsvr32|cmd(\.exe)? /c|-enc(odedcommand)? |bitsadmin|certutil", RegexOptions.IgnoreCase) && tr.Level != "valid") sus.Add(desc + $" — launches a script interpreter at login ({tr.Level}); classic persistence trick");
            else if (OddLocation(exe) && tr.Level != "valid") sus.Add(desc + $" — {tr.Level} program auto-starting from a temp/user/hidden location");
            else if (tr.Level == "invalid") sus.Add(desc + " — broken/invalid signature: " + tr.Signer);
            else look.Add(desc + $" — {(tr.Level == "unsigned" ? "unsigned (unverified publisher)" : "signed by " + tr.Signer + " but in an unusual folder")}");
        }
        info.Add($"Startup entries, tasks and services checked: {fine} verified fine");
        status?.Invoke("CHECKING PROCESSES");
        var procs = Sys.Ps("Get-Process -ErrorAction SilentlyContinue | Where-Object Path | Select-Object -Unique Path | ForEach-Object { $_.Path }", 20).Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(x => x.Trim()).Where(x => x.Length > 0).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        int pf = 0; var flagged = new List<string>();
        foreach (var exe in procs) {
            if (exe.StartsWith(@"C:\Windows\", StringComparison.OrdinalIgnoreCase) && !OddLocation(exe)) { var t0 = TrustOf(exe); if (t0.Level == "microsoft") { pf++; continue; } }
            var tr = TrustOf(exe);
            if (tr.Level is "microsoft" or "store") { pf++; continue; }
            if (LooksLikeWindows(Path.GetFileName(exe)) && !exe.StartsWith(@"C:\Windows\", StringComparison.OrdinalIgnoreCase) && !exe.Contains(@"\Program Files", StringComparison.OrdinalIgnoreCase) && !Regex.IsMatch(exe, @"\\(Google|Microsoft|BraveSoftware)\\", RegexOptions.IgnoreCase)) { sus.Add($"process named like a Windows component running from the wrong place: {exe} ({tr.Level})"); flagged.Add(exe); continue; }
            if (tr.Level == "valid" && !OddLocation(exe)) { pf++; continue; }
            if (OddLocation(exe) && tr.Level != "valid") { sus.Add($"running {tr.Level} program from a temp/user/hidden folder: {exe}"); flagged.Add(exe); }
            else if (tr.Level == "invalid") { sus.Add($"running program with an INVALID signature ({tr.Signer}): {exe}"); flagged.Add(exe); }
            else if (tr.Level == "unsigned") look.Add($"running unsigned program (unverified publisher): {exe}");
            else look.Add($"running {tr.Signer}-signed program from an unusual folder: {exe}");
        }
        info.Add($"Running programs checked: {procs.Count}, {pf} verified fine");
        status?.Invoke("CHECKING FOLDERS");
        // hidden folders / disguised files / temp executables / recent downloads
        try {
            foreach (var d in new DirectoryInfo(Sys.Home).EnumerateDirectories("*", new EnumerationOptions { IgnoreInaccessible = true, AttributesToSkip = 0 })) {
                if ((d.Attributes & FileAttributes.Hidden) == 0 || d.Name.StartsWith(".") || Regex.IsMatch(d.Name, @"^(AppData|Application Data|Cookies|Local Settings|My Documents|NetHood|PrintHood|Recent|SendTo|Start Menu|Templates|IntelGraphicsProfiles|MicrosoftEdgeBackups|ansel|NTUSER|OneDriveTemp)", RegexOptions.IgnoreCase)) continue;
                var exes = d.EnumerateFiles("*.exe", new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true, MaxRecursionDepth = 3 }).Take(3).ToList();
                if (exes.Count > 0) sus.Add($"hidden folder with programs inside: {d.FullName} ({string.Join(", ", exes.Select(e => e.Name))})"); else look.Add("hidden folder in your profile: " + d.FullName);
            }
        } catch { }
        foreach (var root in new[] { Path.Combine(Sys.Home, "Downloads"), Environment.GetFolderPath(Environment.SpecialFolder.Desktop), Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), Path.GetTempPath(), @"C:\Users\Public", @"C:\ProgramData" }) {
            try {
                foreach (var f in new DirectoryInfo(root).EnumerateFiles("*", new EnumerationOptions { IgnoreInaccessible = true, RecurseSubdirectories = root.EndsWith("ProgramData") || root.Contains("Temp"), MaxRecursionDepth = 2 })) {
                    if (Regex.IsMatch(f.Name, @"\.(pdf|docx?|xlsx?|pptx?|jpe?g|png|gif|txt|mp[34]|zip)\.(exe|scr|bat|cmd|js|vbs|ps1|lnk|hta)$", RegexOptions.IgnoreCase)) { sus.Add("program disguised as a document: " + f.FullName); continue; }
                    if (root.Contains("Temp") || root.Contains("Public") || root.Contains("ProgramData")) {
                        if (Regex.IsMatch(f.Extension, @"^\.(exe|scr|bat|cmd|vbs|js|hta)$", RegexOptions.IgnoreCase) && f.LastWriteTime > DateTime.Now.AddDays(-14)) {
                            var tr = TrustOf(f.FullName); if (tr.Level is "microsoft" or "valid") continue;
                            (root.Contains("Temp") ? look : sus).Add($"recent {tr.Level} executable in {root}: {f.FullName}");
                        }
                    } else if (f.LastWriteTime > DateTime.Now.AddDays(-7) && Regex.IsMatch(f.Extension, @"^\.(exe|msi|zip|bat|cmd|vbs|js|ps1|iso|scr)$", RegexOptions.IgnoreCase)) {
                        var tr = f.Extension.Equals(".exe", StringComparison.OrdinalIgnoreCase) || f.Extension.Equals(".msi", StringComparison.OrdinalIgnoreCase) ? TrustOf(f.FullName) : new Trust("n/a", "");
                        if (tr.Level is "microsoft" or "valid") continue;
                        look.Add($"recent download, unverified: {f.FullName} ({f.LastWriteTime:yyyy-MM-dd}){(Watcher.Checked.Contains(f.FullName) ? " [already vetted on arrival]" : "")}");
                    }
                }
            } catch { }
        }
        // browser extensions with broad permissions? too noisy; skip. VirusTotal for flagged
        if (VtKey.Length > 0 && flagged.Count > 0) {
            status?.Invoke("ASKING VIRUSTOTAL");
            foreach (var f in flagged.Take(4)) { try { var vt = VirusTotal(f).GetAwaiter().GetResult(); info.Add($"VirusTotal {Path.GetFileName(f)}: {vt}"); if (Regex.IsMatch(vt, @"^([1-9]\d*) malicious")) sus.Add($"VirusTotal flags {f}: {vt}"); } catch { } }
        } else if (flagged.Count > 0) info.Add("VirusTotal: NOT CHECKED for the flagged binaries (no key set)");
        status?.Invoke("THINKING");
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("SUSPICIOUS (" + sus.Count + "):"); sb.AppendLine(sus.Count == 0 ? "  none" : string.Join("\n", sus.Distinct().Select(s => "  - " + s)));
        sb.AppendLine("WORTH A LOOK (" + look.Count + ", usually fine):"); sb.AppendLine(look.Count == 0 ? "  none" : string.Join("\n", look.Distinct().Take(25).Select(s => "  - " + s)));
        sb.AppendLine("INFO:"); sb.AppendLine(string.Join("\n", info.Select(s => "  " + s.Replace("\n", "\n  "))));
        return sb.ToString();
    }
    static string? ExeFrom(string cmdline) {
        var c = cmdline.Trim(); if (c.Length == 0) return null;
        string exe;
        if (c.StartsWith("\"")) { var e = c.IndexOf('"', 1); exe = e > 0 ? c[1..e] : c.Trim('"'); }
        else { var m = Regex.Match(c, @"^(.+?\.(exe|com|bat|cmd|vbs|js|ps1|lnk|scr|hta|dll))(\s|$)", RegexOptions.IgnoreCase); exe = m.Success ? m.Groups[1].Value : c.Split(' ')[0]; }
        exe = Environment.ExpandEnvironmentVariables(exe);
        if (!Path.IsPathRooted(exe)) { var sys32 = Path.Combine(Environment.SystemDirectory, exe); if (File.Exists(sys32)) return sys32; var w = Sys.Ps($"(Get-Command '{exe.Replace("'", "''")}' -ErrorAction SilentlyContinue).Source", 8); return w.Length > 0 ? w : exe; }
        return exe;
    }

    public static string Quarantine(string path) {
        var p = Sys.Expand(path);
        if (!File.Exists(p) && !Directory.Exists(p)) return "No such file: " + p;
        if (Regex.IsMatch(p, @"^C:\\(Windows|Program Files|Program Files \(x86\))\\", RegexOptions.IgnoreCase)) return "Refused: that is a Windows or Program Files path. If a system file is really infected, run a Defender Offline scan (Windows Security → Scan options → Microsoft Defender Offline scan).";
        if (File.Exists(p) && Regex.IsMatch(Path.GetExtension(p), @"^\.(exe|dll|msi)$", RegexOptions.IgnoreCase)) { var t = TrustOf(p); if (t.Level is "microsoft" or "store") return $"Refused: {p} is verifiably from Microsoft ({t.Signer})."; }
        var dest = Path.Combine(QuarantineDir, DateTime.Now.ToString("yyyyMMdd-HHmmss")); Directory.CreateDirectory(dest);
        var notes = new List<string>();
        // kill processes running it, remove Run-key entries pointing at it, disable tasks
        notes.Add(Sys.Ps($@"$p='{p.Replace("'", "''")}'
Get-Process -ErrorAction SilentlyContinue | Where-Object {{ $_.Path -and $_.Path -like ""$p*"" }} | ForEach-Object {{ Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue; 'killed ' + $_.ProcessName }}
foreach ($k in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run','HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce') {{ $r=Get-ItemProperty $k -ErrorAction SilentlyContinue; if ($r) {{ $r.PSObject.Properties | Where-Object {{ $_.Name -notmatch '^PS' -and $_.Value -like ""*$([IO.Path]::GetFileName($p))*"" }} | ForEach-Object {{ Remove-ItemProperty $k -Name $_.Name -ErrorAction SilentlyContinue; 'removed Run entry ' + $_.Name }} }} }}
Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {{ $_.TaskPath -notlike '\Microsoft\*' -and ($_.Actions | Where-Object {{ $_.Execute -like ""*$([IO.Path]::GetFileName($p))*"" }}) }} | ForEach-Object {{ Disable-ScheduledTask -InputObject $_ -ErrorAction SilentlyContinue | Out-Null; 'disabled task ' + $_.TaskName }}", 40));
        try {
            var target = Path.Combine(dest, Path.GetFileName(p) + ".quarantined");
            if (Directory.Exists(p)) Directory.Move(p, target); else File.Move(p, target);
            File.WriteAllText(Path.Combine(dest, "ORIGIN.txt"), p + "\n" + DateTime.Now + "\nTo restore: rename back (remove .quarantined) and move to the original path.\n");
            return $"Quarantined {p} → {target} (renamed so it cannot run). {string.Join("; ", notes.Where(n => n.Length > 0))}".Trim();
        } catch (Exception e) { return $"Could not move {p}: {e.Message}. {string.Join("; ", notes)}"; }
    }

    /// Watches Downloads and Desktop; vets every new installer/archive/script once it has finished downloading.
    public sealed class Watcher {
        public static readonly Watcher Shared = new();
        public static readonly HashSet<string> Checked = new(StringComparer.OrdinalIgnoreCase);
        public Action<string, string, string>? OnResult;   // file, verdict, detail
        readonly List<FileSystemWatcher> ws = new();
        public bool Running => ws.Count > 0;
        static readonly Regex interesting = new(@"\.(exe|msi|msix|appx|zip|7z|rar|iso|bat|cmd|ps1|vbs|js|scr|hta|lnk)$", RegexOptions.IgnoreCase);
        public void Start() {
            Stop();
            foreach (var d in new[] { Path.Combine(Sys.Home, "Downloads"), Environment.GetFolderPath(Environment.SpecialFolder.Desktop) }) {
                if (!Directory.Exists(d)) continue;
                var w = new FileSystemWatcher(d) { IncludeSubdirectories = false, NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite | NotifyFilters.Size };
                w.Created += (_, e) => Consider(e.FullPath); w.Renamed += (_, e) => Consider(e.FullPath);
                w.EnableRaisingEvents = true; ws.Add(w);
            }
            Log.V("watcher started");
        }
        public void Stop() { foreach (var w in ws) w.Dispose(); ws.Clear(); }
        void Consider(string path) {
            if (!interesting.IsMatch(path) || Regex.IsMatch(path, @"\.(crdownload|part|tmp|partial)$", RegexOptions.IgnoreCase)) return;
            lock (Checked) if (!Checked.Add(path)) return;
            Task.Run(async () => {
                // wait until the size is stable and no browser temp file for it exists
                long last = -1; int stable = 0;
                for (int i = 0; i < 300; i++) {
                    await Task.Delay(1000);
                    if (!File.Exists(path)) { lock (Checked) Checked.Remove(path); return; }
                    long sz; try { sz = new FileInfo(path).Length; using var _ = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.Read); } catch { stable = 0; continue; }
                    if (sz == last && sz > 0) { if (++stable >= 2) break; } else stable = 0;
                    last = sz;
                }
                Log.V("watcher inspecting " + path);
                var (v, d) = Inspect(path, suspiciousSource: true);
                OnResult?.Invoke(path, v, d);
            });
        }
    }
}
