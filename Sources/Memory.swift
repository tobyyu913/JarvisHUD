import Foundation

/// Persistent memory: an all-day log of everything the microphone heard, plus explicit notes
/// ("remember I left the keys in the kitchen drawer"). Stored locally in
/// ~/Library/Application Support/JarvisHUD/.  Transcript files are kept for `keepDays` days.
enum Memory {
    static let keepDays = 14
    static let dir: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("JarvisHUD")
        try? FileManager.default.createDirectory(at: u.appendingPathComponent("heard"), withIntermediateDirectories: true)
        return u
    }()
    private static let q = DispatchQueue(label: "jarvis.memory")
    private static let day: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()
    private static let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f }()

    // MARK: transcript
    private static func file(_ d: Date) -> URL { dir.appendingPathComponent("heard/\(day.string(from: d)).log") }

    /// Append one heard utterance to today's log.
    static func log(_ text: String, at d: Date = Date()) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines); guard !t.isEmpty else { return }
        let line = "[\(stamp.string(from: d))] \(t)\n"
        q.async {
            let f = file(d)
            if let h = try? FileHandle(forWritingTo: f) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
            else { try? line.write(to: f, atomically: true, encoding: .utf8) }
        }
    }

    /// Lines heard in the last `hours`, newest last, trimmed to `maxChars` (keeps the most recent part).
    static func transcript(hours: Double, maxChars: Int = 4000) -> String {
        let cutoff = Date().addingTimeInterval(-hours * 3600)
        var out: [String] = []
        for d in stride(from: 0, through: Int(hours / 24) + 1, by: 1) {
            let date = Date().addingTimeInterval(-Double(d) * 86400)
            guard let s = try? String(contentsOf: file(date), encoding: .utf8) else { continue }
            for l in s.split(separator: "\n") {
                guard l.count > 18, let t = stamp.date(from: String(l.dropFirst().prefix(16))), t >= cutoff else { continue }
                out.append(String(l))
            }
        }
        out.sort()
        var s = out.joined(separator: "\n")
        if s.count > maxChars { s = "…" + s.suffix(maxChars) }
        return s
    }

    /// Search all kept logs for lines containing any of the words (case-insensitive).
    static func search(_ query: String, maxLines: Int = 40) -> String {
        let words = query.lowercased().split(separator: " ").map(String.init).filter { $0.count > 2 }
        guard !words.isEmpty else { return transcript(hours: 24) }
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir.appendingPathComponent("heard"), includingPropertiesForKeys: nil)) ?? []).sorted { $0.path > $1.path }
        var hits: [String] = []
        for f in files {
            guard let s = try? String(contentsOf: f, encoding: .utf8) else { continue }
            for l in s.split(separator: "\n").reversed() where words.contains(where: { l.lowercased().contains($0) }) {
                hits.append(String(l)); if hits.count >= maxLines { return hits.reversed().joined(separator: "\n") }
            }
        }
        return hits.isEmpty ? "(nothing heard matching: \(query))" : hits.reversed().joined(separator: "\n")
    }

    static func forgetToday() { try? FileManager.default.removeItem(at: file(Date())) }
    static func forgetAllHeard() {
        let h = dir.appendingPathComponent("heard")
        try? FileManager.default.removeItem(at: h); try? FileManager.default.createDirectory(at: h, withIntermediateDirectories: true)
    }
    /// Delete transcript files older than keepDays.
    static func prune() {
        let h = dir.appendingPathComponent("heard")
        let cutoff = day.string(from: Date().addingTimeInterval(-Double(keepDays) * 86400))
        for f in (try? FileManager.default.contentsOfDirectory(at: h, includingPropertiesForKeys: nil)) ?? [] where f.deletingPathExtension().lastPathComponent < cutoff {
            try? FileManager.default.removeItem(at: f)
        }
    }

    // MARK: notes ("remember that…")
    private static var notesFile: URL { dir.appendingPathComponent("notes.json") }
    static var notes: [[String: String]] {
        get { (try? JSONSerialization.jsonObject(with: Data(contentsOf: notesFile))) as? [[String: String]] ?? [] }
        set { if let d = try? JSONSerialization.data(withJSONObject: newValue, options: .prettyPrinted) { try? d.write(to: notesFile) } }
    }
    static func remember(_ note: String) -> String {
        var n = notes; n.append(["when": stamp.string(from: Date()), "note": note.trimmingCharacters(in: .whitespacesAndNewlines)]); notes = n
        return "Noted (\(n.count) notes kept)."
    }
    static func forgetNote(matching text: String) -> String {
        var n = notes; let before = n.count
        n.removeAll { ($0["note"] ?? "").lowercased().contains(text.lowercased()) }; notes = n
        return before == n.count ? "No note matched \"\(text)\"." : "Forgot \(before - n.count) note(s)."
    }
    static func forgetAllNotes() { notes = [] }
    static var notesText: String { notes.map { "[\($0["when"] ?? "")] \($0["note"] ?? "")" }.joined(separator: "\n") }
}
