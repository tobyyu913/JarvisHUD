using System.Runtime.InteropServices;

namespace JarvisHUD;

/// Disk clean-up in three tiers: SAFE (nothing gets slower), SLOWER (caches that rebuild), NEVER (user data, Windows).
static class Cleaner {
    public enum Tier { Safe, Slower, Never }
    public record Entry(string Id, Tier Tier, string Title, string Why, string[] Paths, int OlderThanDays = 0, string[]? OnlyExt = null, string? Command = null, bool ToRecycleBin = false);
    static string L => Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
    static string R => Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
    static string H => Sys.Home;
    static string Dl => Path.Combine(H, "Downloads");

    public static readonly Entry[] Catalog = {
        new("recycle_bin", Tier.Safe, "Recycle Bin", "files you already deleted", new[] { "<recycle>" }),
        new("temp", Tier.Safe, "Temporary files", "scratch files apps left behind (files in use are skipped)", new[] { Path.Combine(L, "Temp", "*") }),
        new("crash_dumps", Tier.Safe, "Crash dumps & error reports", "old crash dumps and Windows Error Reporting queues", new[] { Path.Combine(L, "CrashDumps", "*"), Path.Combine(L, "Microsoft", "Windows", "WER", "ReportArchive", "*"), Path.Combine(L, "Microsoft", "Windows", "WER", "ReportQueue", "*") }),
        new("old_installers", Tier.Safe, "Old installers in Downloads", "setup files and archives older than 30 days (moved to the Recycle Bin, not deleted)", new[] { Path.Combine(Dl, "*") }, 30, new[] { ".exe", ".msi", ".msix", ".zip", ".iso", ".7z", ".rar", ".appx", ".appinstaller" }, ToRecycleBin: true),
        new("thumbnails", Tier.Safe, "Thumbnail cache", "Explorer regenerates thumbnails as you browse", new[] { Path.Combine(L, "Microsoft", "Windows", "Explorer", "thumbcache_*.db") }),
        new("delivery_optimization", Tier.Safe, "Windows Update download cache (Delivery Optimization)", "already-installed update files; Windows re-downloads what it needs", new[] { "<dism-do>" }, Command: "Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue; 'done'"),
        new("user_caches", Tier.Slower, "App caches (AppData\\Local cache folders)", "every app rebuilds its cache; first launches are slower", new[] { Path.Combine(L, "*", "cache", "*"), Path.Combine(L, "*", "Cache", "*"), Path.Combine(L, "Packages", "*", "LocalCache", "*", "INetCache", "*"), Path.Combine(L, "Microsoft", "Windows", "INetCache", "*") }),
        new("browser_caches", Tier.Slower, "Browser caches", "pages load slower the first time; logins are kept", new[] { Path.Combine(L, "Google", "Chrome", "User Data", "*", "Cache", "*"), Path.Combine(L, "Google", "Chrome", "User Data", "*", "Code Cache", "*"), Path.Combine(L, "Microsoft", "Edge", "User Data", "*", "Cache", "*"), Path.Combine(L, "Microsoft", "Edge", "User Data", "*", "Code Cache", "*"), Path.Combine(L, "Mozilla", "Firefox", "Profiles", "*", "cache2", "*"), Path.Combine(L, "BraveSoftware", "Brave-Browser", "User Data", "*", "Cache", "*") }),
        new("npm_cache", Tier.Slower, "npm / yarn / pnpm caches", "the next install downloads packages again", new[] { Path.Combine(L, "npm-cache", "*"), Path.Combine(R, "npm-cache", "*"), Path.Combine(L, "Yarn", "Cache", "*"), Path.Combine(L, "pnpm", "store", "*") }),
        new("pip_cache", Tier.Slower, "pip cache", "the next pip install downloads wheels again", new[] { Path.Combine(L, "pip", "cache", "*") }),
        new("nuget_cache", Tier.Slower, "NuGet package cache", "the next .NET restore downloads packages again", new[] { Path.Combine(H, ".nuget", "packages", "*"), Path.Combine(L, "NuGet", "v3-cache", "*") }),
        new("gradle_cache", Tier.Slower, "Gradle caches", "the next Android/Gradle build re-downloads dependencies (minutes)", new[] { Path.Combine(H, ".gradle", "caches", "*"), Path.Combine(H, ".gradle", "daemon", "*"), Path.Combine(H, ".gradle", "wrapper", "dists", "*") }),
        new("cargo_cache", Tier.Slower, "Cargo registry cache", "the next Rust build re-downloads crates", new[] { Path.Combine(H, ".cargo", "registry", "cache", "*"), Path.Combine(H, ".cargo", "registry", "src", "*") }),
        new("go_cache", Tier.Slower, "Go build cache", "the next Go build is slower", new[] { Path.Combine(L, "go-build", "*"), Path.Combine(H, "go", "pkg", "mod", "cache", "download", "*") }),
        new("docker_unused", Tier.Slower, "Docker unused images/containers", "stopped containers, dangling images and build cache; pulled again when needed", Array.Empty<string>(), Command: "if (Get-Command docker -ErrorAction SilentlyContinue) { docker system prune -af 2>&1 | Select-Object -Last 2 } else { 'docker not installed' }"),
        new("spotify_cache", Tier.Slower, "Spotify cache", "songs re-buffer once (downloaded playlists are kept)", new[] { Path.Combine(L, "Spotify", "Storage", "*"), Path.Combine(L, "Packages", "SpotifyAB.SpotifyMusic_*", "LocalCache", "Spotify", "Storage", "*") }),
        new("steam_shader_cache", Tier.Slower, "Steam / game shader caches", "games recompile shaders on first launch (stutter for a few minutes)", new[] { Path.Combine(L, "NVIDIA", "DXCache", "*"), Path.Combine(L, "NVIDIA", "GLCache", "*"), Path.Combine(L, "AMD", "DxCache", "*"), Path.Combine(L, "D3DSCache", "*") }),
        new("windows_old", Tier.Slower, "Previous Windows installation (Windows.old)", "removes the option to roll back the last feature update; needs Disk Cleanup as administrator", new[] { @"C:\Windows.old" }, Command: "<admin>"),
        new("documents", Tier.Never, "Documents", "your files", new[] { Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments) }),
        new("desktop", Tier.Never, "Desktop", "your files", new[] { Environment.GetFolderPath(Environment.SpecialFolder.Desktop) }),
        new("downloads_recent", Tier.Never, "Downloads (recent / non-installer)", "could be things you still need; decide by hand", new[] { Dl }),
        new("pictures_videos", Tier.Never, "Pictures, Videos, Music", "your media", new[] { Environment.GetFolderPath(Environment.SpecialFolder.MyPictures), Environment.GetFolderPath(Environment.SpecialFolder.MyVideos), Environment.GetFolderPath(Environment.SpecialFolder.MyMusic) }),
        new("onedrive", Tier.Never, "OneDrive", "synced; deleting here deletes everywhere", new[] { Path.Combine(H, "OneDrive") }),
        new("appdata_roaming", Tier.Never, "AppData\\Roaming", "app settings, saves, databases", new[] { R }),
        new("programs", Tier.Never, "Program Files", "uninstall apps deliberately (Settings → Apps), not with a cleaner", new[] { Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86) }),
        new("windows", Tier.Never, "Windows system, page file, hibernation file", "Windows manages it (use Storage Sense / Disk Cleanup for system files)", new[] { @"C:\Windows", @"C:\pagefile.sys", @"C:\hiberfil.sys" }),
    };

    public record Item(Entry E, long Bytes, int Count, string Note);
    public record Scan_(DateTime At, List<Item> Items, string Drive, string Big) {
        public string Report() {
            var sb = new System.Text.StringBuilder();
            sb.AppendLine($"Drive: {Drive}");
            foreach (var tier in new[] { Tier.Safe, Tier.Slower, Tier.Never }) {
                var rows = Items.Where(i => i.E.Tier == tier).ToList();
                sb.AppendLine(); sb.AppendLine(tier switch { Tier.Safe => "SAFE TO CLEAN (nothing gets slower):", Tier.Slower => "CAN CLEAN BUT SOMETHING GETS SLOWER AFTERWARDS:", _ => "NEVER CLEAN (user data / Windows):" });
                sb.AppendLine($"  total {Sys.Human(rows.Sum(r => r.Bytes))}");
                foreach (var r in rows.OrderByDescending(r => r.Bytes)) {
                    if (tier != Tier.Never && r.Bytes == 0 && r.Count == 0 && r.Note.Length == 0) continue;
                    sb.AppendLine($"  - {r.E.Id}: {r.E.Title} — {Sys.Human(r.Bytes)}{(r.Count > 0 ? $", {r.Count} items" : "")}{(r.Note.Length > 0 ? " (" + r.Note + ")" : "")} — {r.E.Why}");
                }
            }
            if (Big.Length > 0) { sb.AppendLine(); sb.AppendLine("Biggest files over 1 GB in your profile:"); sb.AppendLine(Big); }
            return sb.ToString();
        }
    }
    public static Scan_? Last;

    static IEnumerable<string> Glob(string pattern) {
        // expand one '*' per path segment; the last segment may be a wildcard
        var parts = pattern.Split('\\'); IEnumerable<string> cur = new[] { parts[0] + "\\" };
        for (int i = 1; i < parts.Length; i++) {
            var seg = parts[i]; var next = new List<string>();
            foreach (var c in cur) {
                try {
                    if (seg.Contains('*')) { if (Directory.Exists(c)) { next.AddRange(Directory.GetDirectories(c, seg)); next.AddRange(Directory.GetFiles(c, seg)); } }
                    else { var p = Path.Combine(c, seg); if (File.Exists(p) || Directory.Exists(p)) next.Add(p); }
                } catch { }
            }
            cur = next; if (!cur.Any()) break;
        }
        return cur;
    }
    static long Size(string path, CancellationToken ct) {
        try {
            if (File.Exists(path)) return new FileInfo(path).Length;
            long t = 0;
            var opts = new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true, AttributesToSkip = FileAttributes.ReparsePoint };
            foreach (var f in new DirectoryInfo(path).EnumerateFiles("*", opts)) { if (ct.IsCancellationRequested) break; try { t += f.Length; } catch { } }
            return t;
        } catch { return 0; }
    }
    static (long, int) Measure(Entry e, CancellationToken ct) {
        if (e.Paths.Length == 1 && e.Paths[0] == "<recycle>") { var q = new SHQUERYRBINFO { cbSize = Marshal.SizeOf<SHQUERYRBINFO>() }; return SHQueryRecycleBin(null, ref q) == 0 ? (q.i64Size, (int)q.i64NumItems) : (0, 0); }
        if (e.Paths.Length == 1 && e.Paths[0] == "<dism-do>") { var s = Sys.Ps("try { (Get-DeliveryOptimizationStatus -ErrorAction Stop | Measure-Object -Property FileSize -Sum).Sum } catch { 0 }", 20); return (long.TryParse(s, out var b) ? b : 0, 0); }
        long tot = 0; int n = 0;
        foreach (var p in e.Paths) foreach (var f in Glob(p)) {
            if (ct.IsCancellationRequested) break;
            if (e.OlderThanDays > 0) { try { if (File.GetLastWriteTime(f) > DateTime.Now.AddDays(-e.OlderThanDays)) continue; } catch { continue; } }
            if (e.OnlyExt != null && !e.OnlyExt.Contains(Path.GetExtension(f).ToLowerInvariant())) continue;
            tot += Size(f, ct); n++;
        }
        return (tot, n);
    }

    public static Scan_ Scan(Action<string>? status = null) {
        status?.Invoke("SCANNING DISK");
        var cts = new CancellationTokenSource(TimeSpan.FromSeconds(75));
        var items = new Item[Catalog.Length];
        Parallel.For(0, Catalog.Length, new ParallelOptions { MaxDegreeOfParallelism = 6 }, i => {
            var e = Catalog[i];
            if (e.Tier == Tier.Never && (e.Id == "windows" || e.Id == "programs")) { var (b, _) = Measure(e, cts.Token); items[i] = new(e, b, 0, "measured roughly"); return; }
            var (bytes, n) = Measure(e, cts.Token);
            var note = e.Command == "<admin>" ? "needs administrator: Settings → System → Storage → Temporary files → Previous Windows installation(s)" : "";
            items[i] = new(e, bytes, n, note);
        });
        var big = "";
        try {
            var opts = new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true, AttributesToSkip = FileAttributes.ReparsePoint | FileAttributes.System, MaxRecursionDepth = 6 };
            var bigs = new List<(long, string)>();
            foreach (var f in new DirectoryInfo(Sys.Home).EnumerateFiles("*", opts)) { if (cts.IsCancellationRequested) break; try { if (f.Length > 1L << 30) bigs.Add((f.Length, f.FullName)); } catch { } }
            big = string.Join("\n", bigs.OrderByDescending(x => x.Item1).Take(12).Select(x => $"  {Sys.Human(x.Item1)}  {x.Item2}"));
        } catch { }
        var sys_ = DriveInfo.GetDrives().FirstOrDefault(d => d.IsReady && d.Name.StartsWith(Path.GetPathRoot(Sys.Home) ?? "C:"));
        var drive = sys_ == null ? "?" : $"{sys_.Name} {Sys.Human(sys_.AvailableFreeSpace)} free of {Sys.Human(sys_.TotalSize)} ({100 * (sys_.TotalSize - sys_.AvailableFreeSpace) / sys_.TotalSize}% used)";
        Last = new(DateTime.Now, items.Where(x => x != null).ToList(), drive, big);
        status?.Invoke("THINKING");
        return Last;
    }

    public static string Describe(IEnumerable<string> ids) {
        var lines = new List<string>();
        foreach (var id in ids) {
            var e = Catalog.FirstOrDefault(x => x.Id == id); if (e == null) { lines.Add($"• {id}: unknown item (skipped)"); continue; }
            var sz = Last?.Items.FirstOrDefault(i => i.E.Id == id)?.Bytes;
            lines.Add($"• {e.Title}{(sz.HasValue ? " — " + Sys.Human(sz.Value) : "")}{(e.Tier == Tier.Never ? " — REFUSED (never tier)" : e.Tier == Tier.Slower ? " — " + e.Why : "")}");
        }
        return string.Join("\n", lines);
    }
    static readonly string[] protectedRoots = { Sys.Home, Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), Environment.GetFolderPath(Environment.SpecialFolder.Desktop), Environment.GetFolderPath(Environment.SpecialFolder.MyPictures), @"C:\Windows", Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), L, R };
    static bool Protected(string p) => protectedRoots.Any(r => string.Equals(p.TrimEnd('\\'), r.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase)) || p.Length < 12;

    public static string Clean(List<string> ids, bool dryRun) {
        if (Last == null) return "Run disk_scan first.";
        var outp = new List<string>(); long freedTotal = 0;
        foreach (var id in ids) {
            var e = Catalog.FirstOrDefault(x => x.Id == id);
            if (e == null) { outp.Add($"{id}: unknown item"); continue; }
            if (e.Tier == Tier.Never) { outp.Add($"{e.Title}: REFUSED — this is user data or Windows and is never cleaned."); continue; }
            if (e.Command == "<admin>") { outp.Add($"{e.Title}: needs administrator rights; open Settings → System → Storage → Temporary files and tick 'Previous Windows installation(s)'."); continue; }
            long freed = 0; int n = 0, failed = 0;
            if (e.Paths.Length == 1 && e.Paths[0] == "<recycle>") {
                var (b, c) = Measure(e, CancellationToken.None);
                if (!dryRun) SHEmptyRecycleBin(IntPtr.Zero, null, 0x1 | 0x2 | 0x4);
                freed = b; n = c;
            } else if (e.Paths.Length == 1 && e.Paths[0] == "<dism-do>") {
                var (b, _) = Measure(e, CancellationToken.None); freed = b;
                if (!dryRun && e.Command != null) Sys.Ps(e.Command, 60);
            } else {
                foreach (var p in e.Paths) foreach (var f in Glob(p)) {
                    if (Protected(f)) { failed++; continue; }
                    if (e.OlderThanDays > 0) { try { if (File.GetLastWriteTime(f) > DateTime.Now.AddDays(-e.OlderThanDays)) continue; } catch { continue; } }
                    if (e.OnlyExt != null && !e.OnlyExt.Contains(Path.GetExtension(f).ToLowerInvariant())) continue;
                    var sz = Size(f, CancellationToken.None);
                    if (!dryRun) {
                        try {
                            if (e.ToRecycleBin) { if (!RecycleFile(f)) { failed++; continue; } }
                            else if (Directory.Exists(f)) DeleteDirBestEffort(f, ref failed);
                            else File.Delete(f);
                        } catch { failed++; continue; }
                    }
                    freed += sz; n++;
                }
                if (!dryRun && e.Command != null && e.Command != "<admin>") outp.Add($"  {e.Title}: {Sys.Ps(e.Command, 90)}");
            }
            freedTotal += freed;
            outp.Add($"{e.Title}: {(dryRun ? "would free" : "freed")} {Sys.Human(freed)}{(n > 0 ? $" ({n} items)" : "")}{(failed > 0 ? $", {failed} in use or protected (skipped)" : "")}");
        }
        var sys_ = DriveInfo.GetDrives().FirstOrDefault(d => d.IsReady && d.Name.StartsWith(Path.GetPathRoot(Sys.Home) ?? "C:"));
        outp.Add($"{(dryRun ? "Would free" : "Freed")} about {Sys.Human(freedTotal)} in total. Free space now: {(sys_ == null ? "?" : Sys.Human(sys_.AvailableFreeSpace))}.");
        if (!dryRun) Last = null;
        return string.Join("\n", outp);
    }
    static void DeleteDirBestEffort(string dir, ref int failed) {
        foreach (var f in Directory.EnumerateFiles(dir, "*", new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true, AttributesToSkip = FileAttributes.ReparsePoint })) { try { File.SetAttributes(f, FileAttributes.Normal); File.Delete(f); } catch { failed++; } }
        try { Directory.Delete(dir, true); } catch { }
    }
    static bool RecycleFile(string path) {
        var op = new SHFILEOPSTRUCT { wFunc = 3 /*FO_DELETE*/, pFrom = path + "\0\0", fFlags = 0x40 | 0x10 | 0x4 /*ALLOWUNDO|NOCONFIRMATION|SILENT*/ };
        return SHFileOperation(ref op) == 0;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 1)] struct SHQUERYRBINFO { public int cbSize; public long i64Size; public long i64NumItems; }
    [DllImport("shell32.dll")] static extern int SHQueryRecycleBin(string? pszRootPath, ref SHQUERYRBINFO pSHQueryRBInfo);
    [DllImport("shell32.dll")] static extern int SHEmptyRecycleBin(IntPtr hwnd, string? pszRootPath, uint dwFlags);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct SHFILEOPSTRUCT { public IntPtr hwnd; public uint wFunc; [MarshalAs(UnmanagedType.LPWStr)] public string pFrom; [MarshalAs(UnmanagedType.LPWStr)] public string? pTo; public ushort fFlags; public bool fAnyOperationsAborted; public IntPtr hNameMappings; [MarshalAs(UnmanagedType.LPWStr)] public string? lpszProgressTitle; }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern int SHFileOperation(ref SHFILEOPSTRUCT FileOp);
}
