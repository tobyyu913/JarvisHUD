import Foundation

/// Troubleshooting helpers for the agent: a quick health snapshot of the Mac, and a deep check of one app.
/// Everything here is read-only; fixes go through the normal shell/applescript tools (with confirmation).
enum Doctor {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    static func sh(_ cmd: String, timeout: Double = 15) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = ["-c", cmd]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        guard (try? p.run()) != nil else { return "" }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
        let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return (String(data: d, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let name = sh("sw_vers -productName", timeout: 3)
        return "\(name) \(v.majorVersion).\(v.minorVersion).\(v.patchVersion) (\(sh("uname -m", timeout: 3)))"
    }

    // MARK: quick health snapshot (~3 s)
    static func diagnose() -> String {
        var out: [String] = []
        let group = DispatchGroup(); let lock = NSLock()
        var parts: [Int: String] = [:]
        func part(_ i: Int, _ f: @escaping () -> String) { group.enter(); DispatchQueue.global().async { let r = f(); lock.lock(); parts[i] = r; lock.unlock(); group.leave() } }

        part(0) {
            let up = sh("uptime", timeout: 3)
            let mem = sh("memory_pressure 2>/dev/null | grep -E 'System-wide memory free percentage' | head -1", timeout: 5)
            let swap = sh("sysctl -n vm.swapusage", timeout: 3)
            let therm = sh("pmset -g therm 2>/dev/null | grep -E 'CPU_Speed_Limit|CPU_Scheduler_Limit' | tr '\\n' ' '", timeout: 3)
            return "System: \(osVersion)\n\(up)\nMemory: \(mem.isEmpty ? "(memory_pressure unavailable)" : mem); swap: \(swap)\nThermal throttling: \(therm.isEmpty ? "none reported" : therm)  (100 = no throttling)"
        }
        part(1) {
            "Top CPU processes (%cpu %mem rss elapsed):\n  " + sh("ps -Arco %cpu,%mem,rss,etime,comm | head -11 | tail -10 | sed 's/^ *//'", timeout: 5).replacingOccurrences(of: "\n", with: "\n  ")
        }
        part(2) {
            "Top memory processes (%mem %cpu rss):\n  " + sh("ps -Armo %mem,%cpu,rss,comm | head -9 | tail -8 | sed 's/^ *//' | sed -E 's#/Applications/([^/]+)\\.app/.*#\\1#; s#.*/([^/]+)$#\\1#'", timeout: 5).replacingOccurrences(of: "\n", with: "\n  ")
        }
        part(3) {
            let busy = sh("ps -Aco %cpu,comm | awk '$1>40 {print}' | grep -E 'kernel_task|mds|mds_stores|mdworker|backupd|photoanalysisd|bird|cloudd|WindowServer|spindump|ReportCrash|XProtect|syspolicyd|softwareupdated|installd|fseventsd' | sed 's/^/  /'", timeout: 5)
            let spot = sh("mdutil -s / 2>/dev/null | tail -1", timeout: 5)
            let tm = sh("tmutil status 2>/dev/null | grep -E 'Running|Percent' | tr -d ' ' | tr '\\n' ' '", timeout: 5)
            return "Known background hogs (>40% CPU): \(busy.isEmpty ? "none" : "\n  " + busy.trimmingCharacters(in: .whitespaces))\nSpotlight: \(spot)\nTime Machine: \(tm.isEmpty ? "idle" : tm)"
        }
        part(4) {
            let disk = sh("df -h / | tail -1 | awk '{print $4\" free of \"$2\" (\"$5\" used)\"}'", timeout: 3)
            let io = sh("iostat -d -c 2 2>/dev/null | tail -1", timeout: 6)
            return "Disk: \(disk); recent I/O (KB/t tps MB/s): \(io)"
        }
        part(5) {
            let crashes = sh("ls -t \(home)/Library/Logs/DiagnosticReports 2>/dev/null | head -400 | awk -F'[-_]' -v now=\"$(date +%s)\" '{print}' | head -200 | while read f; do m=$(stat -f %m \"\(home)/Library/Logs/DiagnosticReports/$f\"); if [ $(( $(date +%s) - m )) -lt 86400 ]; then echo \"  $(date -r $m '+%H:%M') $f\"; fi; done | head -12", timeout: 10)
            return "Crash / hang reports in the last 24 h: \(crashes.isEmpty ? "none" : "\n  " + crashes.trimmingCharacters(in: .whitespaces))"
        }
        part(6) {
            let hung = sh("ps -Ao stat,comm | awk 'NR>1 && ($1 ~ /T/ || $1 ~ /U/) {print \"  \"$0}' | head -5", timeout: 5)
            let agents = sh("ls \(home)/Library/LaunchAgents 2>/dev/null | wc -l | tr -d ' '", timeout: 3)
            let login = sh("osascript -e 'tell application \"System Events\" to get the name of every login item' 2>/dev/null", timeout: 8)
            let net = sh("(ping -c 1 -t 2 1.1.1.1 >/dev/null 2>&1 && echo 'internet reachable' || echo 'NO internet (ping 1.1.1.1 failed)'); (dscacheutil -q host -a name apple.com 2>/dev/null | grep -q ip_address && echo 'DNS ok' || echo 'DNS FAILING')", timeout: 8)
            let wifi = sh("ipconfig getsummary en0 2>/dev/null | grep -E ' SSID|RSSI|Rate' | tr -s ' ' | tr '\\n' ';'", timeout: 5)
            return "Stopped/uninterruptible processes: \(hung.isEmpty ? "none" : "\n" + hung)\nUser launch agents: \(agents); login items: \(login.isEmpty ? "(none / no access)" : login)\nNetwork: \(net.replacingOccurrences(of: "\n", with: "; ")) \(wifi)"
        }
        part(7) {
            let bat = sh("pmset -g batt | tail -1 | sed 's/^ *//'", timeout: 3)
            let updates = sh("defaults read /Library/Preferences/com.apple.SoftwareUpdate LastUpdatesAvailable 2>/dev/null", timeout: 3)
            let sec = sh("spctl --status 2>/dev/null; csrutil status 2>/dev/null | head -1", timeout: 5)
            return "Power: \(bat)\nPending macOS updates: \(updates.isEmpty ? "unknown" : updates)\nSecurity: \(sec.replacingOccurrences(of: "\n", with: "; "))"
        }
        group.wait()
        for i in 0..<8 { if let p = parts[i] { out.append(p) } }
        return out.joined(separator: "\n\n")
    }

    // MARK: one app, in depth (~5-20 s)
    static func appCheck(_ name: String) -> String {
        var out: [String] = []
        let q = name.replacingOccurrences(of: "'", with: "")
        var path = sh("mdfind \"kMDItemKind == 'Application' && kMDItemDisplayName == '\(q)*'c\" 2>/dev/null | grep -v -E '/Library/Developer|\\.app/' | head -1", timeout: 10)
        if path.isEmpty { path = sh("ls -d /Applications/\(q).app /Applications/\(q)*.app \(home)/Applications/\(q)*.app /System/Applications/\(q).app 2>/dev/null | head -1", timeout: 5) }
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            let running = sh("pgrep -il '\(q)' | head -5", timeout: 5)
            return "No application named \"\(name)\" found on disk (searched Spotlight and /Applications)." + (running.isEmpty ? "" : "\nRunning processes matching the name:\n\(running)")
        }
        let plist = path + "/Contents/Info.plist"
        let ver = sh("defaults read '\(plist)' CFBundleShortVersionString 2>/dev/null", timeout: 3)
        let minOS = sh("defaults read '\(plist)' LSMinimumSystemVersion 2>/dev/null", timeout: 3)
        let exe = sh("defaults read '\(plist)' CFBundleExecutable 2>/dev/null", timeout: 3)
        let bundleID = sh("defaults read '\(plist)' CFBundleIdentifier 2>/dev/null", timeout: 3)
        let archs = sh("lipo -archs '\(path)/Contents/MacOS/\(exe)' 2>/dev/null", timeout: 5)
        out.append("App: \(path)\nVersion \(ver.isEmpty ? "?" : ver), bundle \(bundleID), requires macOS \(minOS.isEmpty ? "?" : minOS)+, built for: \(archs.isEmpty ? "?" : archs) (this Mac: \(sh("uname -m", timeout: 2)), \(osVersion))")

        let quarantine = sh("xattr -p com.apple.quarantine '\(path)' 2>/dev/null", timeout: 3)
        let sign = sh("codesign --verify --deep --strict '\(path)' 2>&1 | head -3; codesign -dv '\(path)' 2>&1 | grep -E '^Authority=|TeamIdentifier' | head -2", timeout: 25)
        let gate = sh("spctl --assess --type execute -v '\(path)' 2>&1 | head -2", timeout: 25)
        let translated = sh("ps -Ao comm | grep -q '^\(path)/Contents/MacOS/\(exe)$' && sysctl -n sysctl.proc_translated 2>/dev/null || true", timeout: 3)
        out.append("Gatekeeper / signing:\n  quarantine: \(quarantine.isEmpty ? "not quarantined" : quarantine)\n  codesign: \(sign.replacingOccurrences(of: "\n", with: "\n  "))\n  spctl: \(gate.replacingOccurrences(of: "\n", with: "\n  "))" + (translated.isEmpty ? "" : "\n  translated(Rosetta): \(translated)"))

        let running = sh("pgrep -fl '\(path)/Contents/MacOS/' | head -5", timeout: 5)
        out.append("Running now: \(running.isEmpty ? "no" : "\n  " + running.replacingOccurrences(of: "\n", with: "\n  "))")

        let crashes = sh("ls -t \(home)/Library/Logs/DiagnosticReports 2>/dev/null | grep -iE '^\(exe)|^\(q)' | head -3", timeout: 5)
        if !crashes.isEmpty {
            var cs: [String] = []
            for f in crashes.split(separator: "\n").prefix(2) {
                let fp = "\(home)/Library/Logs/DiagnosticReports/\(f)"
                let head = sh("head -c 20000 '\(fp)' | grep -oE '\"(exception|terminationReason|termination|faultingThread|procLaunch|captureTime|osVersion)\"[^}]{0,200}' | head -6; grep -m1 -A3 'Application Specific Information' '\(fp)' 2>/dev/null; grep -E '^Exception Type|^Termination Reason|^Exception Message' '\(fp)' 2>/dev/null | head -3", timeout: 5)
                cs.append("  \(f):\n    " + head.replacingOccurrences(of: "\n", with: "\n    "))
            }
            out.append("Recent crash reports for this app:\n" + cs.joined(separator: "\n"))
        } else { out.append("Recent crash reports for this app: none") }

        let logs = sh("log show --last 10m --style compact --predicate 'process == \"\(exe)\" OR (eventMessage CONTAINS \"\(exe)\" AND (messageType == error OR messageType == fault))' 2>/dev/null | grep -vE '^Timestamp|^Filtering' | tail -25", timeout: 40)
        out.append("Unified log, last 10 minutes (errors/faults mentioning the app):\n" + (logs.isEmpty ? "  nothing logged" : "  " + logs.replacingOccurrences(of: "\n", with: "\n  ")))
        let launch = sh("log show --last 10m --style compact --predicate 'subsystem == \"com.apple.launchservices\" OR process == \"loginwindow\" OR process == \"syspolicyd\"' 2>/dev/null | grep -i '\(exe)' | tail -8", timeout: 40)
        if !launch.isEmpty { out.append("LaunchServices / Gatekeeper decisions mentioning it:\n  " + launch.replacingOccurrences(of: "\n", with: "\n  ")) }
        return out.joined(separator: "\n\n")
    }
}
