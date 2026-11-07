import Foundation

/// Drive cleaning for the agent. The agent never deletes arbitrary paths: it can only remove entries from this
/// catalog, each tagged with what happens afterwards. The scan sizes every entry so the model can explain the
/// drive before proposing anything; the HUD still asks the user to confirm every clean.
enum Cleaner {
    enum Tier: String { case safe, slower, never }

    struct Entry {
        let id: String, tier: Tier, title: String, note: String
        let paths: [String]            // globs, ~ allowed
        let command: String?           // alternative to deleting paths (e.g. brew cleanup)
        let olderThanDays: Int?        // only files older than this (Downloads installers)
        let onlyExtensions: [String]?
        init(_ id: String, _ tier: Tier, _ title: String, _ note: String, paths: [String] = [], command: String? = nil, olderThanDays: Int? = nil, onlyExtensions: [String]? = nil) {
            self.id = id; self.tier = tier; self.title = title; self.note = note; self.paths = paths; self.command = command; self.olderThanDays = olderThanDays; self.onlyExtensions = onlyExtensions
        }
    }

    static let catalog: [Entry] = [
        // ---- safe: nothing you use gets slower or lost
        Entry("trash", .safe, "Trash", "files you already deleted", paths: ["~/.Trash/*"]),
        Entry("logs", .safe, "User logs", "diagnostic logs of apps you ran", paths: ["~/Library/Logs/*"]),
        Entry("crash_reports", .safe, "Crash reports", "old crash dumps", paths: ["~/Library/Logs/DiagnosticReports/*"]),
        Entry("mail_downloads", .safe, "Mail attachment previews", "Mail re-downloads them from the server when opened", paths: ["~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/*"]),
        Entry("old_installers", .safe, "Old installers in Downloads", "disk images, packages and archives older than 30 days (moved to Trash, not deleted)", paths: ["~/Downloads/*"], olderThanDays: 30, onlyExtensions: ["dmg", "pkg", "zip", "iso", "xip"]),
        Entry("xcode_archives_logs", .safe, "Xcode device logs", "DeviceLogs from connected iPhones/iPads", paths: ["~/Library/Developer/Xcode/iOS Device Logs/*"]),
        Entry("ios_backups_tmp", .safe, "Incomplete iOS backups", "partial backups Finder abandoned (complete backups are kept)", paths: ["~/Library/Application Support/MobileSync/Backup/*-*.tmp", "~/Library/Application Support/MobileSync/Backup/*/Snapshot"]),
        // ---- slower: safe to delete, but something rebuilds and the first use afterwards is slower
        Entry("user_caches", .slower, "App caches", "every app rebuilds its cache; first launches are slower and some logins may need re-entering", paths: ["~/Library/Caches/*"]),
        Entry("browser_caches", .slower, "Browser caches", "pages load slower the first time; logins are kept", paths: ["~/Library/Caches/Google/Chrome/*", "~/Library/Caches/com.apple.Safari/*", "~/Library/Caches/Firefox/*", "~/Library/Caches/com.microsoft.edgemac/*", "~/Library/Caches/company.thebrowser.Browser/*", "~/Library/Application Support/Google/Chrome/*/Service Worker/CacheStorage/*"]),
        Entry("xcode_derived", .slower, "Xcode DerivedData", "the next build of each project is a clean build", paths: ["~/Library/Developer/Xcode/DerivedData/*"]),
        Entry("xcode_device_support", .slower, "Xcode device support", "symbol files per iOS version; re-downloaded the next time that device is plugged in", paths: ["~/Library/Developer/Xcode/iOS DeviceSupport/*", "~/Library/Developer/Xcode/watchOS DeviceSupport/*", "~/Library/Developer/Xcode/tvOS DeviceSupport/*"]),
        Entry("simulator_caches", .slower, "Simulator caches", "simulators keep working, their caches rebuild", paths: ["~/Library/Developer/CoreSimulator/Caches/*"]),
        Entry("homebrew_cache", .slower, "Homebrew downloads", "old bottles; the next upgrade re-downloads", paths: ["~/Library/Caches/Homebrew/*"], command: "brew cleanup --prune=all -s 2>&1 | tail -3"),
        Entry("npm_cache", .slower, "npm / yarn / pnpm caches", "the next install downloads packages again", paths: ["~/.npm/_cacache/*", "~/Library/Caches/Yarn/*", "~/.yarn/berry/cache/*", "~/Library/pnpm/store/*", "~/.cache/yarn/*"]),
        Entry("pip_cache", .slower, "pip cache", "the next pip install downloads wheels again", paths: ["~/Library/Caches/pip/*", "~/.cache/pip/*"]),
        Entry("gradle_cache", .slower, "Gradle caches", "the next Android/Gradle build re-downloads dependencies (minutes)", paths: ["~/.gradle/caches/*", "~/.gradle/daemon/*", "~/.gradle/wrapper/dists/*"]),
        Entry("cargo_cache", .slower, "Cargo registry cache", "the next Rust build re-downloads crates", paths: ["~/.cargo/registry/cache/*", "~/.cargo/registry/src/*"]),
        Entry("go_cache", .slower, "Go build cache", "the next Go build is slower", paths: ["~/Library/Caches/go-build/*", "~/go/pkg/mod/cache/download/*"]),
        Entry("docker_unused", .slower, "Docker unused images/containers", "stopped containers, dangling images and build cache; pulled again when needed", command: "docker system prune -af --volumes=false 2>&1 | tail -2"),
        Entry("spotify_cache", .slower, "Spotify cache", "songs re-buffer once (downloaded playlists are kept)", paths: ["~/Library/Caches/com.spotify.client/*", "~/Library/Application Support/Spotify/PersistentCache/Storage/*"]),
        Entry("quicklook_cache", .slower, "Quick Look thumbnails", "previews regenerate as you browse", command: "qlmanage -r cache >/dev/null 2>&1; echo done"),
        // ---- never: user data or the system; reported for understanding only, the tool refuses to touch these
        Entry("documents", .never, "Documents", "your files", paths: ["~/Documents"]),
        Entry("desktop", .never, "Desktop", "your files", paths: ["~/Desktop"]),
        Entry("downloads_recent", .never, "Downloads (recent / non-installer)", "could be things you still need; decide by hand", paths: ["~/Downloads"]),
        Entry("photos", .never, "Photos library", "your pictures", paths: ["~/Pictures"]),
        Entry("music_movies", .never, "Music & Movies", "your media", paths: ["~/Music", "~/Movies"]),
        Entry("icloud", .never, "iCloud Drive", "synced; deleting here deletes everywhere", paths: ["~/Library/Mobile Documents"]),
        Entry("mail", .never, "Mail", "mailboxes; manage from Mail → Mailbox → Erase Deleted Items", paths: ["~/Library/Mail"]),
        Entry("messages", .never, "Messages attachments", "manage from Messages settings", paths: ["~/Library/Messages"]),
        Entry("ios_backups", .never, "iPhone/iPad backups", "delete only from Finder → device → Manage Backups", paths: ["~/Library/Application Support/MobileSync/Backup"]),
        Entry("app_support", .never, "Application Support", "app data, saves, databases", paths: ["~/Library/Application Support"]),
        Entry("applications", .never, "Applications", "uninstall apps deliberately, not with a cleaner", paths: ["/Applications"]),
        Entry("system", .never, "macOS system + System Data", "sealed system volume, swap, snapshots: macOS manages it", paths: ["/System", "/private/var/vm"]),
    ]

    // MARK: sizing
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static func expand(_ p: String) -> String { p.hasPrefix("~") ? home + p.dropFirst() : p }

    /// Resolve an entry's globs into concrete paths (respecting age/extension filters).
    static func matches(_ e: Entry) -> [String] {
        var out: [String] = []
        for g in e.paths {
            var gt = glob_t()
            defer { globfree(&gt) }
            guard glob(expand(g), GLOB_TILDE | GLOB_NOSORT, nil, &gt) == 0 else { continue }
            for i in 0..<Int(gt.gl_matchc) { if let c = gt.gl_pathv[i] { out.append(String(cString: c)) } }
        }
        if let days = e.olderThanDays {
            let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
            out = out.filter { p in ((try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date ?? .distantFuture) < cutoff }
        }
        if let exts = e.onlyExtensions { out = out.filter { exts.contains(($0 as NSString).pathExtension.lowercased()) } }
        return out.filter { !($0 as NSString).lastPathComponent.hasPrefix(".") || e.id == "trash" }
    }

    /// Byte size of paths via du (fast, follows no symlinks, -x stays on the volume).
    static func size(of paths: [String]) -> Int64 {
        guard !paths.isEmpty else { return 0 }
        var total: Int64 = 0
        for chunk in stride(from: 0, to: paths.count, by: 200) {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/du"); p.arguments = ["-skx"] + paths[chunk..<min(chunk + 200, paths.count)]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { continue }
            let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            for line in (String(data: d, encoding: .utf8) ?? "").split(separator: "\n") { if let k = Int64(line.split(separator: "\t").first ?? "") { total += k * 1024 } }
        }
        return total
    }
    static func human(_ b: Int64) -> String {
        let f = ByteCountFormatter(); f.countStyle = .file; f.allowedUnits = b > 1_000_000_000 ? [.useGB] : [.useMB]; f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: b)
    }

    struct Scan { let when: Date; let text: String; let sizes: [String: Int64] }
    static var last: Scan?

    /// Full report: disk totals, every catalog entry sized, biggest home folders and biggest files.
    /// One parallel du pass over the home folder feeds both the NEVER tier and the "biggest folders" list.
    static func scan(status: ((String) -> Void)? = nil) -> Scan {
        var lines: [String] = []
        var total: Int64 = 0, free: Int64 = 0
        if let a = try? URL(fileURLWithPath: home).resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
           let t = a.volumeTotalCapacity, let f = a.volumeAvailableCapacityForImportantUsage {
            total = Int64(t); free = f
            lines.append("Disk: \(human(total)) total, \(human(free)) free (\(Int(100 * Double(free) / Double(total)))%).")
        }
        status?("MEASURING FOLDERS")
        let fm = FileManager.default
        var folders = ((try? fm.contentsOfDirectory(atPath: home)) ?? []).filter { $0 != "Library" }.map { home + "/" + $0 }
        folders += ((try? fm.contentsOfDirectory(atPath: home + "/Library")) ?? []).map { home + "/Library/" + $0 }
        folders.append("/Applications")
        let folderSize = parallelSizes(folders)
        func under(_ p: String) -> Int64 {   // size of a path from the pass (exact entry, or the sum of its children for ~/Library)
            if let s = folderSize[p] { return s }
            return folderSize.filter { $0.key.hasPrefix(p + "/") }.values.reduce(0, +)
        }

        var sizes: [String: Int64] = [:]
        status?("SIZING CACHES")
        let cleanable = catalog.filter { $0.tier != .never }
        var cleanSizes = [Int64](repeating: 0, count: cleanable.count), cleanCounts = [Int](repeating: 0, count: cleanable.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: cleanable.count) { i in
            let e = cleanable[i]; let paths = matches(e)
            let s = e.id == "docker_unused" ? dockerReclaimable() : size(of: paths)
            lock.lock(); cleanSizes[i] = s; cleanCounts[i] = paths.count; lock.unlock()
        }
        for tier in [Tier.safe, .slower, .never] {
            lines.append("")
            lines.append(["safe": "SAFE TO CLEAN (nothing gets slower or lost):", "slower": "CAN CLEAN, BUT SOMETHING WILL BE SLOWER AFTERWARDS:", "never": "NEVER CLEAN (user data / system; shown only so you understand the drive):"][tier.rawValue]!)
            for e in catalog where e.tier == tier {
                var s: Int64 = 0, count = ""
                if tier == .never {
                    s = e.id == "system" ? max(0, total - free - under(home) - under("/Applications")) : e.paths.map { under(expand($0)) }.reduce(0, +)
                } else if let i = cleanable.firstIndex(where: { $0.id == e.id }) { s = cleanSizes[i]; count = " (\(cleanCounts[i]) items)" }
                sizes[e.id] = s
                guard s > 0 || e.command != nil else { continue }
                lines.append("  - \(e.id): \(e.title) — \(human(s))\(count). \(e.note)")
            }
        }
        lines.append(""); lines.append("Biggest folders in your home (for understanding, not for cleaning):")
        lines.append("  - ~/Library — \(human(under(home + "/Library")))")
        for (p, s) in folderSize.filter({ $0.key != "/Applications" }).sorted(by: { $0.value > $1.value }).prefix(14) {
            lines.append("  - \(p.replacingOccurrences(of: home, with: "~")) — \(human(s))")
        }
        status?("FINDING LARGE FILES")
        lines.append(""); lines.append("Biggest single files (over 1 GB, outside Library):")
        lines.append(contentsOf: bigFiles())
        let sc = Scan(when: Date(), text: lines.joined(separator: "\n"), sizes: sizes)
        last = sc; return sc
    }

    /// du each path concurrently (SSDs cope well; the slow part is directory walking, not bandwidth).
    private static func parallelSizes(_ paths: [String]) -> [String: Int64] {
        var out: [String: Int64] = [:]; let lock = NSLock()
        let sem = DispatchSemaphore(value: 6); let group = DispatchGroup()
        for p in paths {
            group.enter(); sem.wait()
            DispatchQueue.global().async {
                let s = size(of: [p]); lock.lock(); out[p] = s; lock.unlock(); sem.signal(); group.leave()
            }
        }
        group.wait(); return out
    }

    private static func sh(_ cmd: String, timeout: Double = 120) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = ["-lc", cmd]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
        let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(data: d, encoding: .utf8) ?? ""
    }
    private static func dockerReclaimable() -> Int64 {
        guard FileManager.default.fileExists(atPath: "/usr/local/bin/docker") || FileManager.default.fileExists(atPath: "/opt/homebrew/bin/docker") else { return 0 }
        let out = sh("docker system df --format '{{.Reclaimable}}' 2>/dev/null | head -3", timeout: 8)
        var total: Double = 0
        for l in out.split(separator: "\n") { let t = l.split(separator: " ").first.map(String.init) ?? ""; let n = Double(t.filter { "0123456789.".contains($0) }) ?? 0
            total += t.hasSuffix("GB") ? n * 1e9 : t.hasSuffix("MB") ? n * 1e6 : t.hasSuffix("kB") ? n * 1e3 : n }
        return Int64(total)
    }
    private static func bigFiles() -> [String] {
        // prune Library/.Trash/iCloud instead of filtering them, otherwise find still walks millions of files
        let out = sh("find ~ -xdev \\( -path ~/Library -o -path ~/.Trash -o -name node_modules \\) -prune -o -type f -size +1G -print0 2>/dev/null | xargs -0 du -sk 2>/dev/null | sort -rn | head -10", timeout: 60)
        let r = out.split(separator: "\n").compactMap { l -> String? in
            let p = l.split(separator: "\t", maxSplits: 1); guard p.count == 2, let k = Int64(p[0]) else { return nil }
            return "  - \(p[1].replacingOccurrences(of: home, with: "~")) — \(human(k * 1024))"
        }
        return r.isEmpty ? ["  (none)"] : r
    }

    // MARK: cleaning
    /// Human summary of what a clean request would do, for the confirm prompt. nil if nothing valid.
    static func describe(ids: [String]) -> String? {
        let ents = ids.compactMap { id in catalog.first { $0.id == id && $0.tier != .never } }
        guard !ents.isEmpty else { return nil }
        let total = ents.reduce(Int64(0)) { $0 + (last?.sizes[$1.id] ?? 0) }
        return "Clean up \(human(total))?\n\n" + ents.map { "• \($0.title)" + ($0.tier == .slower ? "  (slower afterwards: \($0.note))" : "") }.joined(separator: "\n")
    }

    /// Delete the chosen catalog entries. Refuses anything not in the catalog or tagged never.
    static func clean(ids: [String], dryRun: Bool) -> String {
        var report: [String] = []; var freed: Int64 = 0
        let before = freeSpace()
        for id in ids {
            guard let e = catalog.first(where: { $0.id == id }) else { report.append("\(id): not a cleanable item (ignored)"); continue }
            guard e.tier != .never else { report.append("\(id): REFUSED — \(e.title) is user data/system and is never cleaned"); continue }
            let paths = matches(e)
            let s = size(of: paths); freed += s
            if dryRun { report.append("\(e.title): would remove \(paths.count) items, \(human(s))" + (e.command != nil ? " and run `\(e.command!)`" : "")); continue }
            var removed = 0, failed = 0
            for p in paths {
                // guard rails: only absolute paths inside home (or the catalog's /Applications-free set), never the home dir itself
                let real = URL(fileURLWithPath: p).standardizedFileURL.path
                guard real.hasPrefix(home + "/"), real.count > home.count + 1, !protected(real) else { failed += 1; continue }
                if e.id == "old_installers" {
                    if (try? FileManager.default.trashItem(at: URL(fileURLWithPath: real), resultingItemURL: nil)) != nil { removed += 1 } else { failed += 1 }
                } else {
                    if (try? FileManager.default.removeItem(atPath: real)) != nil { removed += 1 } else { failed += 1 }
                }
            }
            var line = "\(e.title): removed \(removed) items (\(human(s)))" + (failed > 0 ? ", \(failed) skipped (in use or protected)" : "")
            if let c = e.command { line += "; " + sh(c, timeout: 600).trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ") }
            report.append(line)
        }
        if dryRun { return "DRY RUN — nothing deleted.\n" + report.joined(separator: "\n") + "\nTotal that would be freed: \(human(freed))" }
        last = nil   // sizes are stale now
        let after = freeSpace()
        return report.joined(separator: "\n") + "\nFree space: \(human(before)) → \(human(after)) (+\(human(max(0, after - before))))"
    }
    /// User-data roots that are never touched, even if a glob somehow reaches into them.
    private static func protected(_ p: String) -> Bool {
        let roots = ["/Documents", "/Desktop", "/Pictures", "/Music", "/Movies", "/Library/Mobile Documents", "/Library/Mail", "/Library/Messages", "/Library/Keychains"]
        if roots.contains(where: { p == home + $0 || p.hasPrefix(home + $0 + "/") }) { return true }
        let backups = home + "/Library/Application Support/MobileSync/Backup/"
        if p.hasPrefix(backups) { return !(p.hasSuffix(".tmp") || p.hasSuffix("/Snapshot")) }   // only abandoned partial backups
        return false
    }
    static func freeSpace() -> Int64 {
        (try? URL(fileURLWithPath: home).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}
