import Foundation

/// Malware defence: an on-demand scan of the Mac that trusts what is verifiably real (Apple / notarized / App Store)
/// and looks hard at the rest (persistence, hidden folders, unsigned binaries, odd processes), a quarantine tool,
/// and a watcher that vets every new .dmg / .zip / .pkg landing in Downloads or on the Desktop.
enum Guard {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static let quarantineDir = URL(fileURLWithPath: home + "/Library/Application Support/JarvisHUD/quarantine")
    static func sh(_ c: String, timeout: Double = 30) -> String { Installer.sh(c, timeout: timeout) }

    /// Verdict for one binary or bundle: "apple" | "notarized" | "appstore" | "devid" (signed, not notarized) | "adhoc" | "unsigned" | "invalid"
    static func trust(_ path: String) -> String {
        let isBundle = path.hasSuffix(".app") || path.hasSuffix(".appex") || path.hasSuffix(".xpc")
        // iPhone/iPad apps running on Apple Silicon live in a Wrapper and only arrive through the App Store
        if path.contains("/Wrapper/") || FileManager.default.fileExists(atPath: path + "/Wrapper/BundleMetadata.plist") {
            return sh("codesign -dv '\(path)' 2>&1 | grep -c TeamIdentifier", timeout: 10) == "0" ? "adhoc" : "appstore"
        }
        if isBundle {
            // Gatekeeper is the authority for bundles: notarization ticket, App Store receipt, or Apple itself
            let g = sh("spctl --assess --type execute -vv '\(path)' 2>&1 | tr '\\n' ';'", timeout: 30)
            if g.contains("accepted") {
                if g.contains("Notarized") { return "notarized" }
                if g.contains("Mac App Store") { return "appstore" }
                if g.contains("Apple") { return "apple" }
            }
        }
        // --strict is deliberately NOT used: it fails valid apps over harmless Finder metadata
        let out = sh("codesign -dv --verbose=2 '\(path)' 2>&1 | grep -E '^(Authority|Signature)=' | head -3 | tr '\\n' ';'; codesign --verify '\(path)' >/dev/null 2>&1 && echo VALID || echo INVALID", timeout: 30)
        if out.contains("code object is not signed") || out.contains("not signed at all") { return "unsigned" }
        if out.contains("INVALID") {
            // a bare executable inside a bundle, or an unusual bundle layout: judge by who signed it instead
            let why = sh("codesign --verify '\(path)' 2>&1 | head -1", timeout: 20)
            if why.contains("not signed at all") { return "unsigned" }
            if why.contains("sealed resource") || why.contains("have been modified") {   // contents changed after signing: self-updaters do this, tampering does too
                return out.contains("Developer ID") || out.contains("Authority=Apple") || !sh("codesign -dv '\(path)' 2>&1 | grep -c TeamIdentifier", timeout: 10).hasPrefix("0") ? "modified" : "invalid"
            }
            if why.contains("no resources but signature") || why.contains("resource envelope is obsolete") {
                if out.contains("Developer ID") { return "devid" }
                if out.contains("Authority=Software Signing") || out.contains("Authority=Apple") { return "apple" }
                return "adhoc"
            }
            return "invalid"
        }
        if out.contains("Signature=adhoc") { return "adhoc" }
        if out.contains("Authority=Software Signing") { return "apple" }
        if out.contains("Authority=Apple Mac OS Application Signing") || out.contains("Authority=Apple iPhone OS Application Signing") { return "appstore" }
        if out.contains("Developer ID") { return "devid" }
        return out.contains("Authority=") ? "adhoc" : "unsigned"
    }
    static let trusted: Set<String> = ["apple", "notarized", "appstore"]

    static func oddLocation(_ p: String) -> String? {
        let comps = p.split(separator: "/").map(String.init)
        if comps.dropLast().contains(where: { $0.hasPrefix(".") && !["..", "."].contains($0) }) && !p.contains("/.vscode/") && !p.contains("/.cargo/") && !p.contains("/.rustup/") && !p.contains("/.nvm/") && !p.contains("/.local/") && !p.contains("/.bun/") && !p.contains("/.pyenv/") && !p.contains("/.docker/") { return "hidden folder" }
        for bad in ["/tmp/", "/private/tmp/", "/var/tmp/", "/Users/Shared/", "/Library/Caches/", "/Downloads/", "/.Trash/"] where p.contains(bad) { return "runs from \(bad.trimmingCharacters(in: CharacterSet(charactersIn: "/")))" }
        return nil
    }
    static func looksLikeApple(_ name: String) -> Bool { name.lowercased().hasPrefix("com.apple.") || ["mdworker", "launchd", "kernel_task", "WindowServer", "loginwindow", "coreaudiod", "syspolicyd"].contains(name) }

    // MARK: - on-demand scan
    static func scan(status: ((String) -> Void)? = nil) -> String {
        var suspicious: [String] = [], review: [String] = [], info: [String] = []
        var verifiedApps = 0, checkedApps = 0, verifiedProcs = 0
        let lock = NSLock()
        func sus(_ s: String) { lock.lock(); suspicious.append(s); lock.unlock() }
        func rev(_ s: String) { lock.lock(); review.append(s); lock.unlock() }

        // 0. baseline
        status?("CHECKING PROTECTIONS")
        let xpv = sh("defaults read /Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Info.plist CFBundleShortVersionString 2>/dev/null", timeout: 5)
        let xpd = sh("stat -f '%Sm' -t '%Y-%m-%d' /Library/Apple/System/Library/CoreServices/XProtect.bundle 2>/dev/null", timeout: 5)
        let gate = sh("spctl --status 2>&1", timeout: 5), sip = sh("csrutil status 2>&1 | head -1", timeout: 5)
        let fv = sh("fdesetup status 2>&1", timeout: 5), fw = sh("/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>&1", timeout: 5)
        info.append("Protections: \(gate); \(sip); XProtect \(xpv) (updated \(xpd)); \(fv); firewall: \(fw)")
        if !gate.contains("enabled") { sus("Gatekeeper is DISABLED (spctl) — any unsigned app can run without warning") }
        if fw.lowercased().contains("disabled") { rev("Application firewall is off (System Settings → Network → Firewall)") }

        // 1. persistence: launch agents/daemons, login items, cron, profiles
        status?("CHECKING STARTUP ITEMS")
        let plists = sh("ls -1 \(home)/Library/LaunchAgents/*.plist /Library/LaunchAgents/*.plist /Library/LaunchDaemons/*.plist 2>/dev/null", timeout: 10).split(separator: "\n").map(String.init)
        var persistCount = 0
        for pl in plists {
            persistCount += 1
            let prog = sh("/usr/libexec/PlistBuddy -c 'Print :Program' '\(pl)' 2>/dev/null || /usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' '\(pl)' 2>/dev/null", timeout: 5)
            let label = (pl as NSString).lastPathComponent.replacingOccurrences(of: ".plist", with: "")
            guard !prog.isEmpty else { continue }
            var bin = prog
            if ["/bin/sh", "/bin/bash", "/bin/zsh", "/usr/bin/osascript", "/usr/bin/python3", "/usr/bin/env", "/usr/bin/open"].contains(prog) {
                let argsAll = sh("/usr/libexec/PlistBuddy -c 'Print :ProgramArguments' '\(pl)' 2>/dev/null | grep -v -E '^Array|^\\}|^ *$' | head -6 | tr -s ' ' | tr '\\n' ' '", timeout: 5)
                rev("Startup item \(label) runs a script via \(prog): \(argsAll.prefix(160)) (\(pl))")
                continue
            }
            if bin.hasPrefix("~") { bin = home + bin.dropFirst() }
            if !FileManager.default.fileExists(atPath: bin) { rev("Startup item \(label) points to a missing program \(bin) (leftover; harmless but can be removed)"); continue }
            if bin.hasPrefix("/System/") || bin.hasPrefix("/usr/libexec/") || bin.hasPrefix("/usr/sbin/") { continue }
            let t = trust(bin.contains(".app/") ? String(bin[..<bin.range(of: ".app/")!.upperBound].dropLast()) : bin)
            if looksLikeApple(label) && !bin.hasPrefix("/System") && !bin.hasPrefix("/usr") && !bin.hasPrefix("/Library/Apple") { sus("Startup item \(label) pretends to be Apple but runs \(bin) (\(t)) — classic malware disguise (\(pl))"); continue }
            if let odd = oddLocation(bin) { sus("Startup item \(label) \(odd): \(bin) (\(t)) (\(pl))"); continue }
            if ["unsigned", "invalid", "adhoc"].contains(t) { sus("Startup item \(label) runs an \(t) program: \(bin) (\(pl))") }
            else if t == "devid" { rev("Startup item \(label): \(bin) is signed (Developer ID) but not notarized") }
        }
        let cron = sh("crontab -l 2>/dev/null | grep -v '^#' | head -5", timeout: 5)
        if !cron.isEmpty { rev("User cron jobs present: \(cron.replacingOccurrences(of: "\n", with: " | ").prefix(200))") }
        let profiles = sh("profiles list 2>/dev/null | grep -E 'profileIdentifier' | head -5", timeout: 10)
        if !profiles.isEmpty { rev("Configuration profiles installed (can redirect DNS / proxy): \(profiles.replacingOccurrences(of: "\n", with: "; ").prefix(240))") }
        let login = sh("osascript -e 'tell application \"System Events\" to get the path of every login item' 2>/dev/null", timeout: 8)
        for p in login.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !p.isEmpty {
            if let odd = oddLocation(p) { sus("Login item \(odd): \(p)") }
        }
        info.append("Startup items checked: \(persistCount) launch agents/daemons, \(login.isEmpty ? 0 : login.split(separator: ",").count) login items")

        // 2. running processes from user space
        status?("CHECKING RUNNING PROCESSES")
        let procs = sh("ps -Axo pid=,comm= | awk '{pid=$1; $1=\"\"; sub(/^ /,\"\"); print pid\"\\t\"$0}'", timeout: 10).split(separator: "\n")
        var seenBins = Set<String>()
        for line in procs {
            let parts = line.split(separator: "\t", maxSplits: 1); guard parts.count == 2 else { continue }
            let path = String(parts[1])
            guard path.hasPrefix("/"), !path.hasPrefix("/System/"), !path.hasPrefix("/usr/"), !path.hasPrefix("/sbin/"), !path.hasPrefix("/bin/"), !path.hasPrefix("/Library/Apple/"), !path.hasPrefix("/private/var/db/"), !path.hasPrefix("/opt/homebrew/"), !path.hasPrefix("/usr/local/"), !path.hasPrefix("/Applications/Xcode"), !path.contains("/Library/Developer/") else { continue }
            let key = path.range(of: ".app/").map { String(path[..<$0.upperBound].dropLast()) } ?? path
            guard !seenBins.contains(key) else { continue }; seenBins.insert(key)
            if let odd = oddLocation(path) { sus("Running process \(odd): \(path) (pid \(parts[0]))"); continue }
            let t = trust(key)
            if trusted.contains(t) { verifiedProcs += 1; continue }
            let name = (key as NSString).lastPathComponent
            if looksLikeApple(name) { sus("Process named like Apple's but \(t) and outside the system: \(path) (pid \(parts[0]))"); continue }
            if ["unsigned", "invalid"].contains(t) { sus("Running \(t) program: \(path) (pid \(parts[0]))") }
            else if t == "modified" { rev("Running program whose files changed after it was signed (normal for self-updating apps such as Steam or Chrome; tampering looks the same): \(path)") }
            else if t == "adhoc" { rev("Running ad-hoc-signed (self-built or unofficial) program: \(path)") }
            else if t == "devid" { rev("Running signed-but-not-notarized program: \(path)") }
            if seenBins.count > 160 { break }
        }

        // 3. installed apps (skip the verifiably real ones)
        status?("CHECKING APPS")
        let apps = sh("ls -d /Applications/*.app /Applications/*/*.app \(home)/Applications/*.app \(home)/Downloads/*.app \(home)/Desktop/*.app /Users/Shared/*.app /tmp/*.app 2>/dev/null", timeout: 10).split(separator: "\n").map(String.init)
        let sem = DispatchSemaphore(value: 6); let group = DispatchGroup()
        for app in apps {
            group.enter(); sem.wait()
            DispatchQueue.global().async {
                defer { sem.signal(); group.leave() }
                let t = trust(app)
                lock.lock(); checkedApps += 1; lock.unlock()
                if trusted.contains(t) { lock.lock(); verifiedApps += 1; lock.unlock(); return }
                let name = (app as NSString).lastPathComponent
                let quarantined = !sh("xattr -p com.apple.quarantine '\(app)' 2>/dev/null", timeout: 3).isEmpty
                if app.hasPrefix(home + "/Downloads") || app.hasPrefix(home + "/Desktop") || app.hasPrefix("/Users/Shared") || app.hasPrefix("/tmp") { rev("\(name) sits in \(app.replacingOccurrences(of: home, with: "~")) (\(t)) — apps left in Downloads/Desktop are how fake installers hide; move to Applications or delete") ; return }
                if t == "unsigned", sh("grep -il steam '\(app)/Contents/Info.plist' 2>/dev/null", timeout: 3).isEmpty == false || sh("du -sk '\(app)' | cut -f1", timeout: 10) < "600" && app.hasPrefix(home + "/Applications") {
                    rev("\(name): unsigned launcher stub in ~/Applications (Steam creates these for games; harmless if you use Steam)"); return
                }
                if t == "unsigned", app.hasPrefix(home + "/Applications"), !sh("grep -il steam '\(app)/Contents/Info.plist' '\(app)/Contents/MacOS/'* 2>/dev/null | head -1", timeout: 5).isEmpty {
                    rev("\(name): unsigned launcher stub in ~/Applications created by Steam for a game (harmless if you use Steam)"); return
                }
                switch t {
                case "unsigned", "invalid": sus("\(name): \(t == "invalid" ? "signature BROKEN (modified after signing)" : "unsigned app") — \(app)\(quarantined ? "" : " (quarantine flag already cleared)")")
                case "adhoc": rev("\(name): ad-hoc signed (built locally or from source, not a store/dev release) — \(app)")
                case "modified": rev("\(name): signed by a registered developer but files changed after signing (self-updating apps and games do this; so does tampering) — \(app)")
                default: rev("\(name): signed by a developer but not notarized by Apple — \(app)")
                }
            }
        }
        group.wait()
        info.append("Apps checked: \(checkedApps); \(verifiedApps) verified real (Apple, App Store or notarized) and skipped; running programs verified: \(verifiedProcs)")

        // 4. hidden folders and stray executables
        status?("CHECKING HIDDEN FOLDERS")
        let known: Set<String> = [".Trash", ".ssh", ".config", ".cache", ".local", ".npm", ".nvm", ".yarn", ".bun", ".gradle", ".cargo", ".rustup", ".cocoapods", ".vscode", ".vscode-insiders", ".cursor", ".docker", ".kube", ".aws", ".gnupg", ".zsh_sessions", ".oh-my-zsh", ".android", ".m2", ".nuget", ".dotnet", ".pyenv", ".conda", ".jupyter", ".ipython", ".matplotlib", ".cups", ".CFUserTextEncoding", ".DS_Store", ".zshrc", ".zsh_history", ".bash_history", ".bash_profile", ".bashrc", ".profile", ".gitconfig", ".gitignore_global", ".viminfo", ".vim", ".lesshst", ".claude", ".claude.json", ".codex", ".gemini", ".ollama", ".wget-hsts", ".netrc", ".Xauthority", ".swiftpm", ".Trash", ".idlerc", ".iterm2", ".iterm2_shell_integration.zsh", ".hushlogin", ".node_repl_history", ".python_history", ".sqlite_history", ".vscode-server", ".continue", ".expo", ".pub-cache", ".dart", ".dartServer", ".flutter", ".gem", ".bundle", ".rbenv", ".nodenv", ".tool-versions", ".asdf", ".minikube", ".terraform.d", ".gcloud", ".azure", ".cursor-tutor", ".orbstack", ".colima", ".lima", ".rd", ".vagrant.d", ".wine", ".steam", ".mono", ".ServiceHub", ".templateengine", ".nuget", ".omnisharp", ".Spotlight-V100", ".fseventsd", ".TemporaryItems", ".mypy_cache", ".pytest_cache", ".ruff_cache", ".tox", ".venv", ".ngrok2", ".anthropic", ".openai", ".huggingface", ".keras", ".tensorboard", ".ollama", ".lmstudio", ".jenv", ".sdkman", ".gradle", ".kotlin", ".konan", ".zprofile", ".zshenv", ".zcompdump", ".zlogin", ".localized"]
        let hidden = ((try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []).filter { $0.hasPrefix(".") && !known.contains($0) && !$0.hasPrefix(".zcompdump") }
        for h in hidden {
            let p = home + "/" + h
            let execs = sh("find '\(p)' -maxdepth 4 -type f -perm +111 2>/dev/null | head -40 | while read f; do file -b \"$f\" 2>/dev/null | grep -q 'Mach-O' && echo \"$f\"; done | head -5", timeout: 20)
            let size = sh("du -sk '\(p)' 2>/dev/null | cut -f1", timeout: 20)
            let mb = (Int(size) ?? 0) / 1024
            if !execs.isEmpty { sus("Unknown hidden folder ~/\(h) (\(mb) MB) contains executables: \(execs.replacingOccurrences(of: "\n", with: ", ").replacingOccurrences(of: home, with: "~"))") }
            else { rev("Unknown hidden item ~/\(h) (\(mb) MB) — not a tool folder I recognise; probably config from some app") }
        }
        let stray = sh("find /tmp /private/tmp /var/tmp /Users/Shared '\(home)/Library/Caches' '\(home)/Public' -maxdepth 3 -type f -perm +111 -size +20k 2>/dev/null | grep -v -E 'Homebrew|/Caches/(Google|com\\.|org\\.|ms-|JetBrains|pip|go-build|node-gyp|typescript|yarn|Yarn|pnpm|electron|Cypress|ms-playwright|Microsoft|Adobe|Spotify|Discord|Steam|Code|Xcode|CocoaPods|Carthage|KSCrash|bazel|turbo|nx|deno|bun|uv)' | head -200 | while read f; do file -b \"$f\" 2>/dev/null | grep -q 'Mach-O' && echo \"$f\"; done | head -12", timeout: 60)
        for f in stray.split(separator: "\n").map(String.init) {
            let t = trust(f)
            if trusted.contains(t) { continue }
            (["unsigned", "invalid", "adhoc"].contains(t) ? sus : rev)("Executable in a temp/shared location (\(t)): \(f.replacingOccurrences(of: home, with: "~"))")
        }
        // Mach-O hiding behind a document extension anywhere obvious
        let fakeDocs = sh("find '\(home)/Downloads' '\(home)/Desktop' '\(home)/Documents' -maxdepth 2 -type f \\( -name '*.pdf' -o -name '*.docx' -o -name '*.jpg' -o -name '*.png' -o -name '*.txt' \\) -size +50k -newermt '-30 days' 2>/dev/null | head -300 | while read f; do file -b \"$f\" 2>/dev/null | grep -q -E 'Mach-O|shell script|AppleScript' && echo \"$f\"; done | head -5", timeout: 60)
        for f in fakeDocs.split(separator: "\n").map(String.init) { sus("File pretending to be a document but is a program: \(f.replacingOccurrences(of: home, with: "~"))") }

        // 5. recent downloads not yet vetted
        status?("CHECKING RECENT DOWNLOADS")
        let recent = sh("find '\(home)/Downloads' '\(home)/Desktop' -maxdepth 1 -type f \\( -name '*.dmg' -o -name '*.pkg' -o -name '*.zip' \\) -newermt '-7 days' 2>/dev/null | head -10", timeout: 10).split(separator: "\n").map(String.init)
        var dl: [String] = []
        for f in recent where !Watcher.checked.contains(f) {
            let (v, _, _) = Installer.inspect(URL(fileURLWithPath: f))
            Watcher.checked.insert(f)
            dl.append("\((f as NSString).lastPathComponent): \(v)")
            if v.hasPrefix("FAIL") { sus("Downloaded file failed the security check: \(f.replacingOccurrences(of: home, with: "~")) — \(v)") }
        }
        if !dl.isEmpty { info.append("Recent downloads vetted: " + dl.joined(separator: "; ")) }

        // 6. VirusTotal for the flagged binaries (hash only), if a key is set
        if !Installer.vtKey.isEmpty {
            status?("ASKING VIRUSTOTAL")
            let paths = suspicious.compactMap { s -> String? in
                guard let r = s.range(of: #"(/[^ ()]+)"#, options: .regularExpression) else { return nil }
                let p = String(s[r]).replacingOccurrences(of: "~", with: home); return FileManager.default.fileExists(atPath: p) ? p : nil
            }
            var vt: [String] = []
            for p in Array(Set(paths)).prefix(4) {
                let bin = p.hasSuffix(".app") ? sh("echo '\(p)/Contents/MacOS/'\"$(defaults read '\(p)/Contents/Info.plist' CFBundleExecutable 2>/dev/null)\"", timeout: 5) : p
                let sha = sh("shasum -a 256 '\(bin)' 2>/dev/null | cut -d' ' -f1", timeout: 60)
                guard !sha.isEmpty else { continue }
                let (d, code) = Installer.http("https://www.virustotal.com/api/v3/files/\(sha)", headers: ["x-apikey": Installer.vtKey])
                if code == 200, let j = Installer.json(d) as? [String: Any], let st = ((j["data"] as? [String: Any])?["attributes"] as? [String: Any])?["last_analysis_stats"] as? [String: Any] {
                    let mal = st["malicious"] as? Int ?? 0
                    vt.append("\((p as NSString).lastPathComponent): \(mal) malicious of \((st["malicious"] as? Int ?? 0) + (st["suspicious"] as? Int ?? 0) + (st["harmless"] as? Int ?? 0) + (st["undetected"] as? Int ?? 0)) engines")
                    if mal > 0 { sus("VIRUSTOTAL: \(mal) engines flag \(p) as MALICIOUS") }
                } else if code == 404 { vt.append("\((p as NSString).lastPathComponent): never seen by VirusTotal") }
            }
            if !vt.isEmpty { info.append("VirusTotal: " + vt.joined(separator: "; ")) }
        }
        // 7. ClamAV on the hot spots if available
        if !sh("command -v clamscan", timeout: 3).isEmpty {
            status?("RUNNING CLAMAV")
            let cl = sh("clamscan -r -i --no-summary '\(home)/Downloads' '\(home)/Desktop' '\(home)/Library/LaunchAgents' /tmp /Users/Shared 2>/dev/null | head -10", timeout: 600)
            if !cl.isEmpty { for l in cl.split(separator: "\n") { sus("ClamAV: \(l)") } } else { info.append("ClamAV: Downloads, Desktop, LaunchAgents, /tmp, /Users/Shared clean") }
        }

        var out = "MALWARE SCAN — \(Date().formatted(date: .abbreviated, time: .shortened))\n\n"
        out += "SUSPICIOUS (" + "\(suspicious.count)):\n" + (suspicious.isEmpty ? "  nothing found\n" : suspicious.map { "  ! " + $0 }.joined(separator: "\n") + "\n")
        out += "\nWORTH A LOOK (\(review.count); usually legitimate, listed because they could not be verified automatically):\n" + (review.isEmpty ? "  nothing\n" : review.prefix(25).map { "  - " + $0 }.joined(separator: "\n") + "\n")
        out += "\n" + info.joined(separator: "\n")
        out += "\nTo remove something: quarantine_item {\"path\": \"...\"} (moves it to a quarantine folder and unloads it; reversible)."
        return out
    }

    // MARK: - quarantine
    static func quarantine(_ path: String) -> String {
        let p = path.hasPrefix("~") ? home + path.dropFirst() : path
        guard FileManager.default.fileExists(atPath: p) else { return "No such file: \(p)" }
        for protectedRoot in ["/System", "/usr", "/bin", "/sbin", "/Library/Apple", "/private/var/db", home + "/Documents", home + "/Desktop/", home + "/Pictures"] where p.hasPrefix(protectedRoot) && !p.hasSuffix(".app") && !p.hasSuffix(".plist") { return "Refusing to quarantine inside \(protectedRoot)." }
        if trusted.contains(trust(p.hasSuffix(".plist") ? "/nonexistent" : p)) && p.hasSuffix(".app") { return "Refusing: \(p) is verified (Apple / App Store / notarized). If the user insists, they can delete it by hand." }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dest = quarantineDir.appendingPathComponent(stamp)
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        var notes: [String] = []
        if p.hasSuffix(".plist") {
            let label = ((p as NSString).lastPathComponent as NSString).deletingPathExtension
            notes.append("launchctl: " + sh("launchctl bootout gui/$(id -u)/\(label) 2>&1 || launchctl bootout system/\(label) 2>&1 || echo 'not loaded'", timeout: 10))
        }
        // kill running instances from this path
        let killed = sh("pgrep -f '\(p)' | xargs -I{} kill -9 {} 2>/dev/null; echo ok", timeout: 10)
        notes.append("processes: \(killed)")
        let mv = sh("mv '\(p)' '\(dest.path)/' 2>&1", timeout: 30)
        if !mv.isEmpty { return "Could not move (needs admin?): \(mv). Tell the user to remove it by hand: \(p)" }
        // strip execute bits so nothing in quarantine can run by accident
        _ = sh("chmod -R a-x '\(dest.path)' 2>/dev/null; xattr -w com.apple.quarantine '0083;0;JARVIS-quarantine;' '\(dest.path)/\((p as NSString).lastPathComponent)' 2>/dev/null", timeout: 30)
        return "Quarantined \(p) → \(dest.path) (execute permissions removed). \(notes.joined(separator: "; ")). Restore by moving it back; delete the quarantine folder when you are sure."
    }

    // MARK: - download watcher
    final class Watcher {
        static let shared = Watcher()
        static var checked = Set<String>()
        var onResult: ((String, String, String) -> Void)?   // file, verdict, detail
        private var sources: [DispatchSourceFileSystemObject] = []
        private var fds: [Int32] = []
        private var seen = Set<String>()
        private var pending: [String: Int64] = [:]
        private let q = DispatchQueue(label: "jarvis.downloads")
        var enabled: Bool { UserDefaults.standard.object(forKey: "watchDownloads") as? Bool ?? true }

        func start() {
            guard sources.isEmpty else { return }
            for dir in [home + "/Downloads", home + "/Desktop"] {
                seen.formUnion(list(dir))
                let fd = open(dir, O_EVTONLY); guard fd >= 0 else { continue }
                let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .extend], queue: q)
                src.setEventHandler { [weak self] in self?.changed(dir) }
                src.resume(); sources.append(src); fds.append(fd)
            }
        }
        private func list(_ dir: String) -> Set<String> {
            Set(((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).map { dir + "/" + $0 })
        }
        private func changed(_ dir: String) {
            guard enabled else { return }
            let now = list(dir)
            for f in now.subtracting(seen) {
                let ext = (f as NSString).pathExtension.lowercased()
                guard ["dmg", "zip", "pkg"].contains(ext) else { continue }
                seen.insert(f); pending[f] = -1
                q.asyncAfter(deadline: .now() + 3) { [weak self] in self?.settle(f) }
            }
            seen = seen.union(now).filter { FileManager.default.fileExists(atPath: $0) || now.contains($0) }
        }
        /// Wait until the file stops growing (browser finished writing), then vet it.
        private func settle(_ f: String) {
            guard FileManager.default.fileExists(atPath: f) else { pending[f] = nil; return }
            let size = (try? FileManager.default.attributesOfItem(atPath: f))?[.size] as? Int64 ?? 0
            let partial = FileManager.default.fileExists(atPath: f + ".crdownload") || FileManager.default.fileExists(atPath: f + ".part") || size == 0
            if partial || pending[f] != size { pending[f] = size; q.asyncAfter(deadline: .now() + 3) { [weak self] in self?.settle(f) }; return }
            pending[f] = nil
            guard !Watcher.checked.contains(f) else { return }
            Watcher.checked.insert(f)
            let (verdict, detail, _) = Installer.inspect(URL(fileURLWithPath: f))
            vlog("download check \((f as NSString).lastPathComponent): \(verdict)")
            DispatchQueue.main.async { self.onResult?(f, verdict, detail) }
        }
    }
}
