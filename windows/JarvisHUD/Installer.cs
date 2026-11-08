using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace JarvisHUD;

/// Find apps (winget, Microsoft Store, GitHub, web), vet the real installer, install, and fetch docs.
static class Installer {
    public static readonly string Stage = Path.Combine(Settings.Dir, "downloads");
    public record Candidate(string Source, string Id, string Name, string Desc, string Pop, string Price, string Url, bool WellKnown);
    public record Vetted(string Source, string Id, string Verdict, string File, string Detail, DateTime At);
    public static Vetted? Last;
    static bool HasWinget => Sys.Run("winget", "--version", 10).StartsWith("v");

    public static async Task<string> Find(string query) {
        var q = query.Trim(); if (q.Length == 0) return "Give me a short description of the app, sir.";
        Directory.CreateDirectory(Stage);
        var cands = new List<Candidate>();
        var tasks = new List<Task>();
        tasks.Add(Task.Run(() => {
            if (!HasWinget) return;
            var o = Sys.Run("winget", $"search \"{q.Replace("\"", "")}\" --source winget --accept-source-agreements --disable-interactivity", 40);
            foreach (var row in ParseWinget(o)) lock (cands) cands.Add(new("winget", row.id, row.name, "winget package" + (row.extra.Length > 0 ? ", " + row.extra : ""), "winget community repository (hash-verified)", "free or trial (see publisher)", "https://winget.run/pkg/" + row.id.Replace('.', '/'), true));
            var s = Sys.Run("winget", $"search \"{q.Replace("\"", "")}\" --source msstore --accept-source-agreements --disable-interactivity", 40);
            foreach (var row in ParseWinget(s)) lock (cands) cands.Add(new("msstore", row.id, row.name, "Microsoft Store app", "Microsoft Store (sandboxed, auto-updates)", "see Store listing", "https://apps.microsoft.com/detail/" + row.id, true));
        }));
        tasks.Add(Task.Run(async () => {
            try {
                var j = Sys.J(await Sys.GetAsync("https://api.github.com/search/repositories?q=" + Uri.EscapeDataString(q + " windows in:name,description,readme") + "&sort=stars&order=desc&per_page=12", new() { ["Accept"] = "application/vnd.github+json" }, 20));
                foreach (var it in j?["items"] as JsonArray ?? new()) {
                    int stars = (int)(it?["stargazers_count"]?.GetValue<double>() ?? 0); if (stars < 300) continue;
                    if (it?["archived"]?.GetValue<bool>() == true) continue;
                    var lic = Sys.S(it?["license"], "spdx_id"); var full = Sys.S(it, "full_name");
                    lock (cands) cands.Add(new("github", full, full.Split('/').Last(), Sys.S(it, "description"), $"{stars:N0} GitHub stars, license {(lic.Length > 0 ? lic : "none")}", "free (open source)", Sys.S(it, "html_url"), stars >= 3000 && lic.Length > 0 && lic != "NOASSERTION"));
                }
            } catch (Exception e) { Log.V("gh search: " + e.Message); }
        }));
        webNotes = ""; if (Search.Enabled) tasks.Add(Task.Run(async () => { var w = await Search.Run("best " + q + " app for Windows"); lock (cands) webNotes = w; }));
        await Task.WhenAll(tasks);
        var sb = new System.Text.StringBuilder();
        var well = cands.Where(c => c.WellKnown).GroupBy(c => c.Name.ToLowerInvariant()).Select(g => g.OrderBy(c => c.Source == "msstore" ? 0 : c.Source == "winget" ? 1 : 2).First()).Take(14).ToList();
        var less = cands.Where(c => !c.WellKnown).Take(8).ToList();
        sb.AppendLine("WELL-KNOWN OPTIONS (Microsoft Store, winget, or popular GitHub projects):");
        if (well.Count == 0) sb.AppendLine("  none found for this query");
        foreach (var c in well) sb.AppendLine($"  - {c.Name} [source={c.Source} id={c.Id}] — {c.Desc}. {c.Pop}. {c.Price}. {c.Url}");
        sb.AppendLine("LESS ESTABLISHED (smaller GitHub projects; only if the user rejects the above):");
        if (less.Count == 0) sb.AppendLine("  none");
        foreach (var c in less) sb.AppendLine($"  - {c.Name} [source={c.Source} id={c.Id}] — {c.Desc}. {c.Pop}. {c.Url}");
        if (webNotes.Length > 0) { sb.AppendLine("Web search notes:"); sb.AppendLine(webNotes); }
        if (!HasWinget) sb.AppendLine("Note: winget is not available on this PC (install 'App Installer' from the Microsoft Store to enable winget and Store installs).");
        return sb.ToString();
    }
    static string webNotes = "";
    static IEnumerable<(string name, string id, string extra)> ParseWinget(string o) {
        var lines = o.Split('\n').Select(l => l.TrimEnd('\r')).ToList();
        int hdr = lines.FindIndex(l => l.StartsWith("Name") && l.Contains("Id")); if (hdr < 0) yield break;
        int idCol = lines[hdr].IndexOf("Id"); int verCol = lines[hdr].IndexOf("Version");
        foreach (var l in lines.Skip(hdr + 2)) {
            if (l.Length <= idCol || l.StartsWith("-")) continue;
            var name = l[..idCol].Trim(); var rest = l[idCol..];
            var id = (verCol > idCol && l.Length >= verCol ? l[idCol..verCol] : rest.Split(' ')[0]).Trim();
            if (name.Length == 0 || id.Length == 0) continue;
            var extra = verCol > idCol && l.Length > verCol ? "version " + l[verCol..].Trim().Split(' ')[0] : "";
            yield return (name, id, extra);
        }
    }

    public static async Task<string> Vet(string source, string id) {
        Directory.CreateDirectory(Stage);
        try { foreach (var f in Directory.GetFileSystemEntries(Stage)) { try { if (File.GetLastWriteTime(f) < DateTime.Now.AddDays(-7)) { if (Directory.Exists(f)) Directory.Delete(f, true); else File.Delete(f); } } catch { } } } catch { }
        source = source.ToLowerInvariant().Trim(); id = id.Trim();
        if (source == "msstore") {
            var show = Sys.Run("winget", $"show --id {id} --source msstore --accept-source-agreements --disable-interactivity", 40);
            Last = new(source, id, "PASS", "", show, DateTime.Now);
            return "VERDICT: PASS\nMicrosoft Store app: reviewed by Microsoft, sandboxed (runs with limited rights), updated by the Store, uninstalls cleanly. No download to inspect.\n" + show[..Math.Min(1200, show.Length)];
        }
        string file;
        if (source == "winget") {
            if (!HasWinget) return "VERDICT: FAIL\nwinget is not available on this PC.";
            var dir = Path.Combine(Stage, "winget-" + Regex.Replace(id, @"[^\w.\-]", "_")); Directory.CreateDirectory(dir);
            var o = Sys.Run("winget", $"download --id {id} --exact --source winget --download-directory \"{dir}\" --accept-source-agreements --accept-package-agreements --disable-interactivity", 300);
            file = Directory.EnumerateFiles(dir, "*", SearchOption.AllDirectories).Where(f => Regex.IsMatch(f, @"\.(exe|msi|msix|appx|zip|msixbundle|appxbundle)$", RegexOptions.IgnoreCase)).OrderByDescending(f => new FileInfo(f).Length).FirstOrDefault() ?? "";
            if (file.Length == 0) return "VERDICT: WARN\nwinget could not download the installer for inspection (older winget versions lack 'download'; or the publisher blocks direct downloads):\n" + o[..Math.Min(600, o.Length)] + "\nIf you proceed, winget itself still verifies the SHA-256 of the installer against the manifest before installing.";
            var manifest = Directory.EnumerateFiles(dir, "*.yaml", SearchOption.AllDirectories).FirstOrDefault();
            var (v, d) = Guard.Inspect(file, suspiciousSource: false);
            d += "\nwinget: the manifest's SHA-256 is verified on install" + (manifest != null ? $"; manifest {Path.GetFileName(manifest)}" : "");
            Last = new(source, id, v, file, d, DateTime.Now);
            return d;
        }
        if (source == "github") {
            var rel = Sys.J(await Sys.GetAsync($"https://api.github.com/repos/{id}/releases/latest", new() { ["Accept"] = "application/vnd.github+json" }, 20));
            var assets = rel?["assets"] as JsonArray ?? new();
            var arch = System.Runtime.InteropServices.RuntimeInformation.OSArchitecture.ToString().ToLowerInvariant();
            var pick = assets.Select(a => (name: Sys.S(a, "name"), url: Sys.S(a, "browser_download_url"), size: (long)(a?["size"]?.GetValue<double>() ?? 0)))
                .Where(a => Regex.IsMatch(a.name, @"\.(exe|msi|msix|zip|appx|msixbundle)$", RegexOptions.IgnoreCase) && !Regex.IsMatch(a.name, @"(linux|darwin|mac|osx|\.dmg|\.deb|\.rpm|\.AppImage|android|\.apk)", RegexOptions.IgnoreCase))
                .OrderByDescending(a => Regex.IsMatch(a.name, @"(win|windows)", RegexOptions.IgnoreCase) ? 2 : 0)
                .ThenByDescending(a => arch == "arm64" ? (Regex.IsMatch(a.name, "arm64", RegexOptions.IgnoreCase) ? 1 : 0) : (Regex.IsMatch(a.name, @"(x64|amd64|win64|x86_64)", RegexOptions.IgnoreCase) ? 1 : 0))
                .ThenBy(a => a.name.EndsWith(".zip") ? 1 : 0).FirstOrDefault();
            if (pick.url == null || pick.url.Length == 0) return $"VERDICT: FAIL\nNo Windows installer in the latest GitHub release of {id} (tag {Sys.S(rel, "tag_name")}). Assets: {string.Join(", ", assets.Select(a => Sys.S(a, "name")))}";
            var dir = Path.Combine(Stage, "github-" + id.Replace('/', '_')); Directory.CreateDirectory(dir);
            file = Path.Combine(dir, pick.name);
            using (var s = await Sys.Http.GetStreamAsync(pick.url)) using (var fs = File.Create(file)) await s.CopyToAsync(fs);
            try { File.WriteAllText(file + ":Zone.Identifier", "[ZoneTransfer]\r\nZoneId=3\r\nHostUrl=" + pick.url + "\r\n"); } catch { }   // keep SmartScreen's mark of the web
            var (v, d) = Guard.Inspect(file, suspiciousSource: true);
            d += $"\nGitHub release {Sys.S(rel, "tag_name")} published {Sys.S(rel, "published_at")[..Math.Min(10, Sys.S(rel, "published_at").Length)]}; asset {pick.name} ({Sys.Human(pick.size)})";
            Last = new(source, id, v, file, d, DateTime.Now);
            return d;
        }
        return $"Unknown source '{source}'. Use winget, msstore or github.";
    }

    public static string DescribeInstall(string source, string id) => source.ToLowerInvariant() switch {
        "msstore" => $"{id} from the Microsoft Store (opens the Store page / winget msstore install)",
        "winget" => $"{id} with winget (silent install, hash-verified){(Last?.Verdict is string v && Last.Id == id ? $" — vet: {v}" : "")}",
        "github" => $"{id} from GitHub: run the downloaded installer{(Last?.Verdict is string v2 && Last.Id == id ? $" — vet: {v2}" : "")}",
        _ => $"{id} from {source}"
    };
    public static string Install(string source, string id) {
        source = source.ToLowerInvariant().Trim(); id = id.Trim();
        if (Last == null || Last.Id != id || Last.Source != source) return "Refused: run app_vet for this exact app first.";
        if (Last.Verdict == "FAIL") return "Refused: the vet verdict was FAIL. Pick another option.";
        if ((DateTime.Now - Last.At).TotalMinutes > 30) return "Refused: the vet is older than 30 minutes; run app_vet again.";
        switch (source) {
            case "msstore": {
                var o = Sys.Run("winget", $"install --id {id} --source msstore --accept-source-agreements --accept-package-agreements --disable-interactivity", 600);
                if (o.Contains("Successfully installed")) return "Installed from the Microsoft Store.\n" + o[^Math.Min(400, o.Length)..];
                try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("ms-windows-store://pdp/?productid=" + id) { UseShellExecute = true }); } catch { }
                return "Opened the Microsoft Store page; the user installs with the Store's own button (winget output: " + o[^Math.Min(300, o.Length)..] + ")";
            }
            case "winget": {
                var o = Sys.Run("winget", $"install --id {id} --exact --source winget --accept-source-agreements --accept-package-agreements --disable-interactivity --silent", 900);
                return (o.Contains("Successfully installed") ? "Installed. " : "winget finished; check the output. ") + "If a UAC prompt appeared the user had to approve it.\n" + o[^Math.Min(800, o.Length)..];
            }
            case "github": {
                var f = Last.File; if (!File.Exists(f)) return "The downloaded installer is gone; run app_vet again.";
                var ext = Path.GetExtension(f).ToLowerInvariant();
                if (ext == ".zip") {
                    var dest = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", id.Split('/').Last());
                    Directory.CreateDirectory(dest); System.IO.Compression.ZipFile.ExtractToDirectory(f, dest, true);
                    var exe = Directory.EnumerateFiles(dest, "*.exe", SearchOption.AllDirectories).OrderBy(x => x.Count(c => c == '\\')).FirstOrDefault();
                    if (exe != null) { var lnk = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), Path.GetFileNameWithoutExtension(exe) + ".lnk"); Sys.Ps($"$s=(New-Object -ComObject WScript.Shell).CreateShortcut('{lnk.Replace("'", "''")}'); $s.TargetPath='{exe.Replace("'", "''")}'; $s.Save()", 15); return $"Unpacked to {dest} and added a Start-menu shortcut for {Path.GetFileName(exe)} (portable app, no installer)."; }
                    return $"Unpacked to {dest}.";
                }
                if (ext == ".msi") { var o = Sys.Run("msiexec.exe", $"/i \"{f}\" /passive /norestart", 900); return "msiexec finished (exit text: " + (o.Length == 0 ? "ok" : o) + "). If UAC asked, the user approved it."; }
                if (ext is ".msix" or ".appx" or ".msixbundle") { var o = Sys.Ps($"Add-AppxPackage -Path '{f.Replace("'", "''")}' -ErrorAction Stop; 'installed'", 300); return o; }
                try { var p = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(f) { UseShellExecute = true }); p?.WaitForExit(600_000); return $"Ran the installer {Path.GetFileName(f)}; it exited with code {p?.ExitCode}. SmartScreen may have shown its own prompt first."; }
                catch (Exception e) { return "Could not run the installer: " + e.Message; }
            }
        }
        return "Unknown source.";
    }

    public static async Task<string> Docs(string source, string id) {
        source = source.ToLowerInvariant().Trim(); id = id.Trim();
        var sb = new System.Text.StringBuilder();
        try {
            if (source == "github") {
                var raw = await Sys.GetAsync($"https://api.github.com/repos/{id}/readme", new() { ["Accept"] = "application/vnd.github.raw+json" }, 20);
                sb.AppendLine("README (GitHub):"); sb.AppendLine(raw[..Math.Min(6000, raw.Length)]);
            } else {
                var o = Sys.Run("winget", $"show --id {id} --source {source} --accept-source-agreements --disable-interactivity", 40);
                sb.AppendLine(o[..Math.Min(3000, o.Length)]);
                var home = Regex.Match(o, @"(Homepage|Publisher Url):\s*(\S+)").Groups[2].Value;
                var gh = Regex.Match(o, @"https://github\.com/([\w.\-]+/[\w.\-]+)").Groups[1].Value;
                if (gh.Length > 0) { try { var raw = await Sys.GetAsync($"https://api.github.com/repos/{gh}/readme", new() { ["Accept"] = "application/vnd.github.raw+json" }, 20); sb.AppendLine("README (GitHub):"); sb.AppendLine(raw[..Math.Min(5000, raw.Length)]); } catch { } }
                else if (home.Length > 0) { try { var html = await Sys.GetAsync(home, null, 20); var text = Regex.Replace(Regex.Replace(html, @"<script[\s\S]*?</script>|<style[\s\S]*?</style>", ""), "<[^>]+>", " "); text = Regex.Replace(System.Net.WebUtility.HtmlDecode(text), @"\s+", " "); sb.AppendLine("Homepage text:"); sb.AppendLine(text[..Math.Min(3000, text.Length)]); } catch { } }
            }
        } catch (Exception e) { sb.AppendLine("docs lookup failed: " + e.Message); }
        if (Search.Enabled) { sb.AppendLine("Web:"); sb.AppendLine(await Search.Run(id.Split('/').Last() + " how to use guide windows")); }
        return sb.ToString();
    }
}
