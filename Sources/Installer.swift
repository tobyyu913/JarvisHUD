import Foundation

/// App discovery, vetting and installation for the agent.
/// Flow: find_app → (user picks) → app_vet (download + security checks, nothing installed) → install_app (HUD confirm) → app_docs.
enum Installer {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static let stage = URL(fileURLWithPath: home + "/Library/Application Support/JarvisHUD/downloads")
    static var vtKey: String { UserDefaults.standard.string(forKey: "vtKey") ?? "" }
    static var brew: String? { ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) } }

    static func sh(_ cmd: String, timeout: Double = 30) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = ["-c", "setopt NULL_GLOB NO_NOMATCH; " + cmd]
        var env = ProcessInfo.processInfo.environment; env["HOMEBREW_NO_AUTO_UPDATE"] = "1"; env["HOMEBREW_NO_ENV_HINTS"] = "1"; env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        guard (try? p.run()) != nil else { return "" }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
        let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return (String(data: d, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func http(_ url: String, headers: [String: String] = [:], timeout: Double = 20) -> (Data?, Int) {
        guard let u = URL(string: url) else { return (nil, 0) }
        var req = URLRequest(url: u); req.timeoutInterval = timeout
        req.setValue("JarvisHUD/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let sem = DispatchSemaphore(value: 0); var data: Data?; var code = 0
        URLSession.shared.dataTask(with: req) { d, r, _ in data = d; code = (r as? HTTPURLResponse)?.statusCode ?? 0; sem.signal() }.resume()
        _ = sem.wait(timeout: .now() + timeout + 2)
        return (data, code)
    }
    static func json(_ d: Data?) -> Any? { d.flatMap { try? JSONSerialization.jsonObject(with: $0) } }
    static func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?.replacingOccurrences(of: "&", with: "%26").replacingOccurrences(of: "+", with: "%2B") ?? s }

    // MARK: - find
    /// Homebrew's public analytics: cask installs over the last 30 days. Cached for a day on disk.
    static func caskInstalls() -> [String: Int] {
        let cache = stage.appendingPathComponent("cask-analytics.json")
        try? FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        var data: Data? = nil
        if let m = (try? cache.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, Date().timeIntervalSince(m) < 86400 { data = try? Data(contentsOf: cache) }
        if data == nil { let (d, code) = http("https://formulae.brew.sh/api/analytics/cask-install/30d.json", timeout: 25); if code == 200, let d = d { data = d; try? d.write(to: cache) } }
        guard let j = json(data) as? [String: Any], let items = j["items"] as? [[String: Any]] else { return [:] }
        var out: [String: Int] = [:]
        for i in items { if let c = i["cask"] as? String, let n = i["count"] as? String { out[c] = Int(n.replacingOccurrences(of: ",", with: "")) ?? 0 } }
        return out
    }

    struct Candidate { let line: String; let popular: Bool; let score: Int }

    static func find(query: String) -> String {
        let group = DispatchGroup(); let lock = NSLock(); var all: [Candidate] = []; var notes: [String] = []
        func add(_ c: [Candidate]) { lock.lock(); all += c; lock.unlock() }
        func note(_ n: String) { lock.lock(); notes.append(n); lock.unlock() }
        func part(_ f: @escaping () -> Void) { group.enter(); DispatchQueue.global().async { f(); group.leave() } }
        let q = query.replacingOccurrences(of: "'", with: "")

        part {   // Homebrew casks, ranked by 30-day installs
            guard brew != nil else { note("Homebrew is not installed on this Mac (brew.sh; needs admin once), so casks are unavailable."); return }
            let installs = caskInstalls()
            let out = sh("brew search --desc --casks '\(q)' 2>/dev/null | grep -v '^==>' | grep ':' | head -25", timeout: 90)
            var cs: [Candidate] = []
            for l in out.split(separator: "\n") {
                let id = String(l.split(separator: ":").first ?? "").trimmingCharacters(in: .whitespaces)
                let n = installs[id] ?? 0
                cs.append(Candidate(line: "  [brew_cask] \(l) — \(n >= 1000 ? "\(n / 1000)k" : "\(n)") installs/30d", popular: n >= 500, score: n))
            }
            add(cs)
            let f = sh("brew search --desc --formulae '\(q)' 2>/dev/null | grep -v '^==>' | grep ':' | head -5", timeout: 90)
            if !f.isEmpty { note("Command-line tools in Homebrew (source=brew): " + f.replacingOccurrences(of: "\n", with: "; ")) }
        }
        part {   // GitHub, ranked by stars
            let (d, code) = http("https://api.github.com/search/repositories?q=\(enc(query + " macos"))&sort=stars&order=desc&per_page=10", headers: ["Accept": "application/vnd.github+json"])
            guard code == 200, let j = json(d) as? [String: Any], let items = j["items"] as? [[String: Any]] else { note("GitHub search failed (HTTP \(code))"); return }
            add(items.compactMap { r -> Candidate? in
                guard let full = r["full_name"] as? String else { return nil }
                let stars = r["stargazers_count"] as? Int ?? 0, archived = r["archived"] as? Bool == true
                let lic = ((r["license"] as? [String: Any])?["spdx_id"] as? String) ?? "no license"
                let desc = (r["description"] as? String ?? "").prefix(110)
                return Candidate(line: "  [github] \(full) — ★\(stars), updated \((r["pushed_at"] as? String ?? "").prefix(10)), \(lic)\(archived ? ", ARCHIVED" : ""): \(desc)",
                                 popular: stars >= 3000 && !archived && lic != "no license", score: stars)
            })
        }
        part {   // Mac App Store, ranked by number of ratings
            let (d, code) = http("https://itunes.apple.com/search?entity=macSoftware&limit=10&term=\(enc(query))")
            guard code == 200, let j = json(d) as? [String: Any], let items = j["results"] as? [[String: Any]] else { note("Mac App Store search failed (HTTP \(code))"); return }
            add(items.compactMap { r -> Candidate? in
                guard let name = r["trackName"] as? String, let id = r["trackId"] as? Int else { return nil }
                let n = r["userRatingCount"] as? Int ?? 0, rating = r["averageUserRating"] as? Double ?? 0
                let desc = (r["description"] as? String ?? "").replacingOccurrences(of: "\n", with: " ").prefix(100)
                return Candidate(line: "  [mas] \(name) (id \(id)) — \(r["formattedPrice"] as? String ?? "?"), \(String(format: "%.1f", rating))★ from \(n) ratings, by \(r["sellerName"] as? String ?? ""): \(desc)",
                                 popular: n >= 100 && rating >= 4.0, score: n * 10)
            })
        }
        part {   // web, only as colour
            guard Search.enabled else { return }
            let sem = DispatchSemaphore(value: 0); var out = ""
            Search.run("best \(query) app for mac") { out = $0; sem.signal() }; _ = sem.wait(timeout: .now() + 25)
            if !out.isEmpty { note("Web search (\"best \(query) app for mac\"): " + String(out.prefix(2000))) }
        }
        group.wait()
        let popular = all.filter { $0.popular }.sorted { $0.score > $1.score }
        let rest = all.filter { !$0.popular }.sorted { $0.score > $1.score }
        var out = "WELL-KNOWN OPTIONS (big, established apps — offer these first; id/source in brackets):\n"
        out += popular.isEmpty ? "  none found for this query\n" : popular.prefix(10).map { $0.line }.joined(separator: "\n") + "\n"
        out += "\nLESS ESTABLISHED (small, new, unlicensed or archived — mention only if the user turns down the well-known ones, and say they are less proven):\n"
        out += rest.isEmpty ? "  none\n" : rest.prefix(12).map { $0.line }.joined(separator: "\n") + "\n"
        if !notes.isEmpty { out += "\n" + notes.joined(separator: "\n") }
        return out
    }

    // MARK: - vet
    struct Vetted { let source: String, id: String, name: String, file: URL?, verdict: String, appPath: String?, kind: String }
    static var last: Vetted?

    static func vet(source: String, id: String) -> String {
        try? FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        // downloads older than a week are of no further use
        for f in (try? FileManager.default.contentsOfDirectory(at: stage, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let d = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, d < Date().addingTimeInterval(-7 * 86400) { try? FileManager.default.removeItem(at: f) }
        }
        switch source {
        case "mas":
            let (d, _) = http("https://itunes.apple.com/lookup?id=\(enc(id))")
            guard let j = json(d) as? [String: Any], let r = (j["results"] as? [[String: Any]])?.first, let name = r["trackName"] as? String else { return "No App Store app with id \(id)." }
            let masOK = !sh("command -v mas", timeout: 3).isEmpty
            last = Vetted(source: "mas", id: id, name: name, file: nil, verdict: "PASS", appPath: nil, kind: "mas")
            return "VERDICT: PASS — \(name) \(r["version"] as? String ?? "") by \(r["sellerName"] as? String ?? ""), \(r["formattedPrice"] as? String ?? ""), reviewed and sandboxed by Apple. Minimum macOS \(r["minimumOsVersion"] as? String ?? "?"). "
                + (masOK ? "Ready to install with mas." : "The `mas` command-line tool is missing: install_app will first run `brew install mas`; the user must be signed in to the App Store app. Paid apps must have been bought already.")
        case "brew", "brew_cask":
            guard brew != nil else { return "VERDICT: FAIL — Homebrew is not installed." }
            let isCask = source == "brew_cask"
            let info = sh("brew info \(isCask ? "--cask" : "--formula") --json=v2 '\(id)' 2>&1", timeout: 60)
            guard let j = json(info.data(using: .utf8)) as? [String: Any], let item = ((j[isCask ? "casks" : "formulae"] as? [[String: Any]])?.first) else { return "VERDICT: FAIL — Homebrew does not know '\(id)': \(info.prefix(300))" }
            let name = (item["name"] as? [String])?.first ?? item["name"] as? String ?? id
            let homepage = item["homepage"] as? String ?? ""
            let desc = item["desc"] as? String ?? ""
            let version = (item["version"] as? String) ?? ((item["versions"] as? [String: Any])?["stable"] as? String) ?? "?"
            var notes: [String] = ["\(name) \(version) — \(desc)", "Homepage: \(homepage)"]
            if item["deprecated"] as? Bool == true || item["disabled"] as? Bool == true { notes.append("WARNING: Homebrew marks this \(item["disabled"] as? Bool == true ? "disabled" : "deprecated"): \(item["deprecation_reason"] as? String ?? item["disable_reason"] as? String ?? "")") }
            if !isCask {
                last = Vetted(source: source, id: id, name: name, file: nil, verdict: "PASS", appPath: nil, kind: "formula")
                return "VERDICT: PASS — command-line tool built/bottled by Homebrew from \(homepage).\n" + notes.joined(separator: "\n")
            }
            // download the actual artifact so it can be inspected before anything is installed
            let fetchOut = sh("brew fetch --cask '\(id)' 2>&1 | tail -3", timeout: 600)
            let fetched = sh("brew --cache --cask '\(id)' 2>/dev/null | tail -1", timeout: 60)
            guard !fetched.isEmpty, FileManager.default.fileExists(atPath: fetched) else { return "VERDICT: FAIL — could not download the cask artifact (\(fetchOut.prefix(200)))." }
            let (verdict, detail, appPath) = inspect(URL(fileURLWithPath: fetched))
            last = Vetted(source: source, id: id, name: name, file: URL(fileURLWithPath: fetched), verdict: verdict, appPath: appPath, kind: "cask")
            return "VERDICT: \(verdict)\n" + notes.joined(separator: "\n") + "\nArtifact: \(fetched)\n" + detail
        case "github":
            let parts = id.split(separator: "/"); guard parts.count == 2 else { return "github id must be owner/repo" }
            let (rd, rc) = http("https://api.github.com/repos/\(id)", headers: ["Accept": "application/vnd.github+json"])
            guard rc == 200, let repo = json(rd) as? [String: Any] else { return "VERDICT: FAIL — repository \(id) not found (HTTP \(rc))." }
            let stars = repo["stargazers_count"] as? Int ?? 0, created = (repo["created_at"] as? String ?? "").prefix(10), pushed = (repo["pushed_at"] as? String ?? "").prefix(10)
            var notes = ["\(id) — ★\(stars), created \(created), last push \(pushed), \(((repo["license"] as? [String: Any])?["spdx_id"] as? String) ?? "no license")", (repo["description"] as? String ?? "")]
            if repo["archived"] as? Bool == true { notes.append("WARNING: repository is archived (unmaintained).") }
            if stars < 50 { notes.append("WARNING: very few stars; little community review of this code.") }
            let (ld, lc) = http("https://api.github.com/repos/\(id)/releases/latest", headers: ["Accept": "application/vnd.github+json"])
            guard lc == 200, let rel = json(ld) as? [String: Any], let assets = rel["assets"] as? [[String: Any]] else { return "VERDICT: FAIL — \(id) publishes no releases, so there is nothing safe to install (building from source is out of scope).\n" + notes.joined(separator: "\n") }
            let arm = sh("uname -m", timeout: 2) == "arm64"
            func score(_ a: [String: Any]) -> Int {
                let n = (a["name"] as? String ?? "").lowercased(); var s = 0
                if n.hasSuffix(".dmg") { s += 30 } else if n.hasSuffix(".pkg") { s += 25 } else if n.hasSuffix(".zip") { s += 20 } else { return -1 }
                if n.contains("mac") || n.contains("darwin") || n.contains("osx") { s += 10 }
                if n.contains("universal") { s += 8 }
                if arm && (n.contains("arm64") || n.contains("aarch64") || n.contains("apple")) { s += 8 }
                if !arm && (n.contains("x86_64") || n.contains("x64") || n.contains("intel")) { s += 8 }
                if n.contains("linux") || n.contains("win") || n.contains(".exe") || n.contains(".deb") || n.contains(".appimage") || n.contains("ios") { s -= 50 }
                return s
            }
            guard let asset = assets.max(by: { score($0) < score($1) }), score(asset) > 0, let url = asset["browser_download_url"] as? String, let aname = asset["name"] as? String else {
                return "VERDICT: FAIL — latest release \(rel["tag_name"] as? String ?? "") has no macOS .dmg/.pkg/.zip asset. Assets: \(assets.compactMap { $0["name"] as? String }.joined(separator: ", "))\n" + notes.joined(separator: "\n")
            }
            notes.append("Release \(rel["tag_name"] as? String ?? "") (\((rel["published_at"] as? String ?? "").prefix(10))), asset \(aname) (\((asset["size"] as? Int ?? 0) / 1_000_000) MB)")
            let dest = stage.appendingPathComponent(aname)
            try? FileManager.default.removeItem(at: dest)
            let dl = sh("curl -L --fail --max-time 600 -o '\(dest.path)' '\(url)' 2>&1 | tail -1; xattr -w com.apple.quarantine '0083;\(String(Int(Date().timeIntervalSince1970), radix: 16));JARVIS;' '\(dest.path)'", timeout: 620)
            guard FileManager.default.fileExists(atPath: dest.path) else { return "VERDICT: FAIL — download failed: \(dl.prefix(200))" }
            let suspicious = stars < 200 || repo["archived"] as? Bool == true || (repo["license"] as? [String: Any]) == nil
            let (verdict, detail, appPath) = inspect(dest, suspicious: suspicious)
            last = Vetted(source: "github", id: id, name: (repo["name"] as? String) ?? id, file: dest, verdict: verdict, appPath: appPath, kind: (aname as NSString).pathExtension.lowercased())
            return "VERDICT: \(verdict)\n" + notes.joined(separator: "\n") + "\nDownloaded to: \(dest.path)\n" + detail
        default:
            return "Unknown source '\(source)'. Use brew_cask, brew, mas or github."
        }
    }

    /// .app / .pkg bundles inside a mounted image or unzipped folder. Never follows symlinks: disk images ship an
    /// "Applications" symlink to the real /Applications, and following it would inspect the wrong apps entirely.
    static func findBundles(_ root: String, depth: Int = 2) -> [String] {
        sh("find '\(root)' -maxdepth \(depth) -not -type l \\( -name '*.app' -o -name '*.pkg' \\) -not -path '*/.background/*' -not -path '*/.Trashes/*' 2>/dev/null | head -3", timeout: 20)
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty && !$0.hasPrefix("/Applications") }
    }

    /// Security inspection of a downloaded dmg/pkg/zip/app: signature, notarization (Gatekeeper), VirusTotal, ClamAV.
    static func inspect(_ file: URL, suspicious: Bool = false) -> (String, String, String?) {
        var lines: [String] = []; var bad = 0, warn = 0; var appPath: String?
        let ext = file.pathExtension.lowercased()
        let sha = sh("shasum -a 256 '\(file.path)' | cut -d' ' -f1", timeout: 120)
        lines.append("SHA-256: \(sha)")
        var notarizedAll = true, sawTarget = false

        // 2. unpack to find the app / pkg
        var targets: [String] = []
        var mount: String?
        switch ext {
        case "dmg":
            let out = sh("hdiutil attach -nobrowse -readonly -noverify -noautoopen '\(file.path)' 2>&1 | grep -E '/Volumes/' | sed -E 's/.*(\\/Volumes\\/.*)$/\\1/' | tail -1", timeout: 120)
            if out.isEmpty { lines.append("Could not mount the disk image (password protected or corrupt)"); bad += 1 }
            else { mount = out; targets = findBundles(out) }
        case "zip":
            let dir = stage.appendingPathComponent(file.deletingPathExtension().lastPathComponent + "_unzipped"); try? FileManager.default.removeItem(at: dir)
            _ = sh("ditto -x -k '\(file.path)' '\(dir.path)' 2>&1", timeout: 300)
            targets = findBundles(dir.path, depth: 3)
        case "pkg", "app": targets = [file.path]
        default: lines.append("Unsupported artifact type .\(ext)"); bad += 1
        }
        if targets.isEmpty && bad == 0 { lines.append("No .app or .pkg found inside the download"); bad += 1 }

        // 3. per target: signature + Gatekeeper
        for t in targets.prefix(2) {
            let isPkg = t.hasSuffix(".pkg")
            if !isPkg && appPath == nil { appPath = t }
            let sign = isPkg ? sh("pkgutil --check-signature '\(t)' 2>&1 | grep -E 'Status|Developer ID|Apple' | head -3 | tr -s ' ' | tr '\\n' ';'", timeout: 60)
                             : sh("(codesign --verify --deep --strict '\(t)' 2>&1 && echo 'valid signature') | head -2 | tr '\\n' ';'; codesign -dv '\(t)' 2>&1 | grep -E '^Authority=' | head -1", timeout: 120)
            let gate = sh("spctl --assess --type \(isPkg ? "install" : "execute") -vv '\(t)' 2>&1 | head -3 | tr '\\n' ';'", timeout: 120)
            lines.append("\((t as NSString).lastPathComponent): signature → \(sign.isEmpty ? "(none)" : sign)\n  Gatekeeper → \(gate)")
            let notarized = gate.contains("accepted") && (gate.contains("Notarized") || gate.contains("Mac App Store") || gate.contains("Apple System"))
            let signedDevID = sign.contains("Developer ID") || sign.contains("Apple")
            sawTarget = true; if !notarized { notarizedAll = false }
            if gate.contains("rejected") || sign.contains("not signed") || sign.contains("code object is not signed") { bad += 1 }
            else if !notarized { warn += 1; lines.append("  → not notarized by Apple (no Apple malware scan on record)\(signedDevID ? ", but signed with a Developer ID" : "")") }
            if !isPkg {
                let archs = sh("lipo -archs \"$(defaults read '\(t)/Contents/Info.plist' CFBundleExecutable 2>/dev/null | sed \"s#^#\(t)/Contents/MacOS/#\")\" 2>/dev/null", timeout: 10)
                let minOS = sh("defaults read '\(t)/Contents/Info.plist' LSMinimumSystemVersion 2>/dev/null", timeout: 5)
                if !archs.isEmpty { lines.append("  built for \(archs)\(archs.contains("arm64") ? "" : " (Intel only: runs under Rosetta on this Mac)"), minimum macOS \(minOS.isEmpty ? "?" : minOS)") }
            }
        }
        // 4. VirusTotal (hash lookup, the file is never uploaded). With a key it always runs. Without one it is
        //    only *mentioned* when something is off: Apple-notarized apps from reputable sources need no nagging.
        let sketchy = suspicious || !notarizedAll || !sawTarget || bad > 0 || warn > 0
        if !vtKey.isEmpty, !sha.isEmpty {
            let (d, code) = http("https://www.virustotal.com/api/v3/files/\(sha)", headers: ["x-apikey": vtKey])
            if code == 200, let j = json(d) as? [String: Any], let st = ((j["data"] as? [String: Any])?["attributes"] as? [String: Any])?["last_analysis_stats"] as? [String: Any] {
                let mal = st["malicious"] as? Int ?? 0, sus = st["suspicious"] as? Int ?? 0, ok = st["harmless"] as? Int ?? 0, und = st["undetected"] as? Int ?? 0
                lines.append("VirusTotal: \(mal) malicious, \(sus) suspicious, \(ok + und) clean of \(mal + sus + ok + und) engines")
                if mal > 0 { bad += 1 } else if sus > 2 { warn += 1 }
            } else if code == 404 { lines.append("VirusTotal: this exact file has never been scanned there (no verdict)") }
            else { lines.append("VirusTotal: lookup failed (HTTP \(code))") }
        } else if sketchy {
            lines.append("VirusTotal: NOT CHECKED — this download is not fully trusted (see above), so an antivirus look-up is recommended before installing. Ask the user whether to add a free VirusTotal key (◎ → VirusTotal Key…, then re-vet) or to proceed at their own risk.")
        }
        // ClamAV if present
        if !sh("command -v clamscan", timeout: 3).isEmpty {
            let scanTarget = mount ?? targets.first ?? file.path
            let cl = sh("clamscan -r --infected --no-summary '\(scanTarget)' 2>&1 | head -3", timeout: 300)
            lines.append("ClamAV: \(cl.isEmpty ? "clean" : "FOUND: \(cl)")"); if !cl.isEmpty { bad += 1 }
        } else { lines.append("ClamAV: not installed (optional: brew install clamav)") }
        if let m = mount { _ = sh("hdiutil detach '\(m)' -quiet 2>&1 || (sleep 1; hdiutil detach '\(m)' -force -quiet)", timeout: 30) }

        let verdict = bad > 0 ? "FAIL (do not install)" : warn > 0 ? "WARN (signed but not fully vetted; install only if the user accepts the risk)" : "PASS (signed, notarized by Apple\(vtKey.isEmpty ? "" : ", no antivirus detections"))"
        return (verdict, lines.joined(separator: "\n"), appPath)
    }

    // MARK: - install
    static func describeInstall(source: String, id: String) -> String {
        guard let v = last, v.source == source, v.id == id else { return "Install \(id) from \(source)? (NOT VETTED YET)" }
        return "Install \(v.name) from \(source == "mas" ? "the Mac App Store" : source == "github" ? "GitHub (\(id))" : "Homebrew (\(id))")?\n\nSecurity check: \(v.verdict)"
    }
    static func install(source: String, id: String) -> String {
        guard let v = last, v.source == source, v.id == id else { return "Refusing: run app_vet for \(source) \(id) first." }
        guard !v.verdict.hasPrefix("FAIL") else { return "Refusing: the security check failed (\(v.verdict)). Suggest a different app." }
        switch v.kind {
        case "mas":
            if sh("command -v mas", timeout: 3).isEmpty { let b = sh("brew install mas 2>&1 | tail -2", timeout: 600); if sh("command -v mas", timeout: 3).isEmpty { return "Could not install the mas tool: \(b)" } }
            let out = sh("mas install \(id) 2>&1 | tail -4", timeout: 900)
            let path = sh("mdfind \"kMDItemAppStoreCategory == '*' && kMDItemDisplayName == '\(v.name.replacingOccurrences(of: "'", with: ""))*'\" | head -1", timeout: 10)
            return "mas: \(out)\n" + (path.isEmpty ? "If it says not signed in / not purchased: open the App Store app, sign in (and buy the app if it is paid), then say install again." : "Installed at \(path).")
        case "formula":
            return "brew: " + sh("brew install '\(id)' 2>&1 | tail -6", timeout: 1200) + "\n" + sh("brew info '\(id)' 2>/dev/null | sed -n '/==> Caveats/,/==>/p' | head -20", timeout: 30)
        case "cask":
            let out = sh("brew install --cask '\(id)' 2>&1 | tail -8", timeout: 1200)
            let apps = sh("brew info --cask --json=v2 '\(id)' 2>/dev/null", timeout: 30)
            var appName = ""
            if let j = json(apps.data(using: .utf8)) as? [String: Any], let c = (j["casks"] as? [[String: Any]])?.first, let arts = c["artifacts"] as? [[String: Any]] {
                for a in arts { if let ap = (a["app"] as? [Any])?.first as? String { appName = ap; break } }
            }
            let path = appName.isEmpty ? "" : "/Applications/\(appName)"
            let caveats = sh("brew info --cask '\(id)' 2>/dev/null | sed -n '/==> Caveats/,$p' | head -15", timeout: 30)
            return "brew: \(out)\n" + (path.isEmpty || !FileManager.default.fileExists(atPath: path) ? (out.contains("sudo") || out.contains("password") ? "This cask needs an admin password (it ships a .pkg); run `brew install --cask \(id)` in Terminal." : "") : "Installed: \(path)") + (caveats.isEmpty ? "" : "\n" + caveats)
        case "dmg", "zip":
            guard let app = v.appPath else { return "No .app found in the download to copy." }
            // re-mount dmg if needed (inspect unmounted it)
            var src = app; var mount: String?
            if v.kind == "dmg", let f = v.file {
                mount = sh("hdiutil attach -nobrowse -readonly -noverify -noautoopen '\(f.path)' 2>&1 | grep -E '/Volumes/' | sed -E 's/.*(\\/Volumes\\/.*)$/\\1/' | tail -1", timeout: 120)
                guard let m = mount, !m.isEmpty else { return "Could not re-mount the disk image." }
                src = findBundles(m).first { $0.hasSuffix(".app") } ?? ""
            }
            let dest = "/Applications/" + (src as NSString).lastPathComponent
            if FileManager.default.fileExists(atPath: dest) { _ = sh("mv '\(dest)' '\(home)/.Trash/\((dest as NSString).lastPathComponent)-replaced-\(Int(Date().timeIntervalSince1970))' 2>&1", timeout: 30) }
            let cp = sh("ditto '\(src)' '\(dest)' 2>&1", timeout: 600)
            if let m = mount { _ = sh("hdiutil detach '\(m)' -quiet 2>&1 || (sleep 1; hdiutil detach '\(m)' -force -quiet)", timeout: 30) }
            guard FileManager.default.fileExists(atPath: dest) else { return "Copy failed: \(cp)" }
            // keep quarantine so Gatekeeper does its first-launch check; it prompts once
            let gate = sh("spctl --assess --type execute '\(dest)' 2>&1 | head -1", timeout: 60)
            return "Installed: \(dest)\nGatekeeper on first launch: \(gate.isEmpty ? "accepted" : gate). macOS will show its usual \"downloaded from the internet\" prompt the first time; that is expected."
        case "pkg":
            guard let f = v.file else { return "No package file." }
            _ = sh("open '\(f.path)'", timeout: 10)
            return "A .pkg installer needs an admin password, which only the user can type. I opened the installer window (\(f.lastPathComponent)); the user should click through it. Say so clearly."
        default: return "Unsupported artifact kind \(v.kind)."
        }
    }

    // MARK: - docs
    static func docs(source: String, id: String) -> String {
        func readme(_ repo: String) -> String {
            let (d, code) = http("https://api.github.com/repos/\(repo)/readme", headers: ["Accept": "application/vnd.github.raw+json"])
            guard code == 200, let d = d, var s = String(data: d, encoding: .utf8) else { return "" }
            s = s.replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression)
            s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            s = s.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            return "README (\(repo)):\n" + String(s.prefix(7000))
        }
        switch source {
        case "github": return readme(id).ifEmpty("No README found for \(id).")
        case "brew", "brew_cask":
            let info = sh("brew info \(source == "brew_cask" ? "--cask" : "") --json=v2 '\(id)' 2>/dev/null", timeout: 60)
            guard let j = json(info.data(using: .utf8)) as? [String: Any], let item = ((j[source == "brew_cask" ? "casks" : "formulae"] as? [[String: Any]])?.first) else { return "Unknown \(id)" }
            let home = item["homepage"] as? String ?? ""
            var out = "Homepage: \(home)\nDescription: \(item["desc"] as? String ?? "")\n"
            let cav = sh("brew info \(source == "brew_cask" ? "--cask" : "") '\(id)' 2>/dev/null | sed -n '/==> Caveats/,$p' | head -20", timeout: 30)
            if !cav.isEmpty { out += cav + "\n" }
            if let r = home.range(of: #"github\.com/([^/]+/[^/#?]+)"#, options: .regularExpression) {
                out += readme(String(home[r]).replacingOccurrences(of: "github.com/", with: "").replacingOccurrences(of: ".git", with: ""))
            } else if !home.isEmpty {
                let (d, _) = http(home); if let d = d, let html = String(data: d, encoding: .utf8) {
                    let text = html.replacingOccurrences(of: #"<script[\s\S]*?</script>|<style[\s\S]*?</style>|<[^>]+>"#, with: " ", options: .regularExpression).replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
                    out += "Homepage text: " + String(text.prefix(3500))
                }
            }
            return out
        case "mas":
            let (d, _) = http("https://itunes.apple.com/lookup?id=\(enc(id))")
            guard let j = json(d) as? [String: Any], let r = (j["results"] as? [[String: Any]])?.first else { return "Unknown App Store id \(id)" }
            return "\(r["trackName"] as? String ?? "") by \(r["sellerName"] as? String ?? "")\nSupport: \(r["sellerUrl"] as? String ?? "")\nWhat's new: \(String((r["releaseNotes"] as? String ?? "").prefix(600)))\n\nDescription:\n\(String((r["description"] as? String ?? "").prefix(5000)))"
        default: return "Unknown source"
        }
    }
}

extension String { func ifEmpty(_ alt: String) -> String { isEmpty ? alt : self } }
