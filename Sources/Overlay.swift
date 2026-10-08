import Cocoa
import QuartzCore

// A HUD "card" with title, bordered translucent box, animated reveal.
final class Card: CALayer {
    let titleL = CATextLayer(), body = CATextLayer(), border = CAShapeLayer(), bars = CALayer()
    var fullWidth: CGFloat = 0
    init(title: String, frame: CGRect, fromRight: Bool = false) {
        super.init()
        self.frame = frame; fullWidth = frame.width
        anchorPoint = CGPoint(x: fromRight ? 1 : 0, y: 1); position = CGPoint(x: fromRight ? frame.maxX : frame.minX, y: frame.maxY)
        backgroundColor = NSColor(red: 0, green: 0.12, blue: 0.22, alpha: 0.65).cgColor
        cornerRadius = 5; masksToBounds = true
        border.fillColor = nil; border.strokeColor = CYAN.cgColor; border.lineWidth = 1.2
        border.path = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerWidth: 5, cornerHeight: 5, transform: nil)
        addSublayer(border)
        let accent = CALayer(); accent.backgroundColor = CYAN.cgColor; accent.frame = CGRect(x: 0, y: bounds.height - 26, width: 4, height: 26); addSublayer(accent)
        titleL.string = title; titleL.fontSize = 12; titleL.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        titleL.foregroundColor = CYAN.cgColor; titleL.contentsScale = 2
        titleL.frame = CGRect(x: 12, y: bounds.height - 22, width: bounds.width - 24, height: 16); addSublayer(titleL)
        body.fontSize = 11.5; body.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        body.foregroundColor = NSColor(red: 0.7, green: 0.93, blue: 1, alpha: 1).cgColor; body.contentsScale = 2; body.isWrapped = true
        body.frame = CGRect(x: 12, y: 8, width: bounds.width - 24, height: bounds.height - 36); addSublayer(body)
        bars.frame = body.frame; addSublayer(bars)
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    func setLines(_ lines: [String]) { body.string = lines.joined(separator: "\n") }
    struct Row { let label = CATextLayer(), value = CATextLayer(), bg = CALayer(), fg = CALayer() }
    var rows: [Row] = []
    // rows of (label, value 0..1, text)
    func setBars(_ data: [(String, Double, String)], rowH: CGFloat = 16) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        body.string = ""
        while rows.count > data.count { let r = rows.removeLast(); [r.label, r.value, r.bg, r.fg].forEach { $0.removeFromSuperlayer() } }
        while rows.count < data.count {
            let r = Row()
            for t in [r.label, r.value] { t.fontSize = 11; t.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular); t.contentsScale = 2 }
            r.label.foregroundColor = body.foregroundColor; r.value.foregroundColor = CYAN.cgColor; r.value.alignmentMode = .right
            r.bg.backgroundColor = DIM.withAlphaComponent(0.2).cgColor
            [r.label, r.bg, r.fg, r.value].forEach { bars.addSublayer($0) }
            rows.append(r)
        }
        let w = bars.bounds.width, labelW: CGFloat = 76, valW: CGFloat = 96
        for (i, d) in data.enumerated() {
            let r = rows[i], y = bars.bounds.height - CGFloat(i + 1) * rowH, v = CGFloat(min(max(d.1, 0), 1))
            r.label.string = d.0; r.label.frame = CGRect(x: 0, y: y, width: labelW, height: rowH)
            r.value.string = d.2; r.value.frame = CGRect(x: w - valW, y: y, width: valW, height: rowH)
            let bw = w - labelW - valW - 8
            r.bg.frame = CGRect(x: labelW, y: y + 5, width: bw, height: 6)
            r.fg.frame = CGRect(x: labelW, y: y + 5, width: bw * v, height: 6)
            r.fg.backgroundColor = (v > 0.85 ? NSColor(red: 1, green: 0.35, blue: 0.3, alpha: 1) : v > 0.6 ? NSColor(red: 1, green: 0.75, blue: 0.2, alpha: 1) : CYAN).cgColor
        }
        CATransaction.commit()
    }
    func reveal(delay: Double) {
        CATransaction.begin(); CATransaction.setDisableActions(true); bounds.size.width = 0; opacity = 0; CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            CATransaction.begin(); CATransaction.setAnimationDuration(0.4)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            self.bounds.size.width = self.fullWidth; self.opacity = 1; CATransaction.commit()
        }
    }
}

final class OverlayView: NSView {
    var cpu: Card!, mem: Card!, sensors: Card!, net: Card!, procs: Card!, sys: Card!
    var radar = CALayer(), sweep = CAShapeLayer(), clock = CATextLayer()
    var timer: Timer?
    let top: CGFloat, bottom: CGFloat
    init(frame: NSRect, topInset: CGFloat, bottomInset: CGFloat) { top = topInset; bottom = bottomInset; super.init(frame: frame); wantsLayer = true; build() }
    required init?(coder: NSCoder) { fatalError() }

    func build() {
        let W = bounds.width, H = bounds.height - top, m: CGFloat = 18, cw: CGFloat = 330, B = bottom + 18
        cpu     = Card(title: "CPU  //  CORES",         frame: CGRect(x: m, y: H - m - 300, width: cw, height: 300))
        mem     = Card(title: "MEMORY  //  STORAGE",    frame: CGRect(x: m, y: H - m - 300 - 14 - 130, width: cw, height: 130))
        procs   = Card(title: "PROCESSES  //  TOP",     frame: CGRect(x: m, y: B, width: cw, height: 190))
        sensors = Card(title: "THERMAL  //  FANS",      frame: CGRect(x: W - m - cw, y: H - m - 440, width: cw, height: 440), fromRight: true)
        net     = Card(title: "NETWORK  //  POWER",     frame: CGRect(x: W - m - cw, y: B, width: cw, height: 150), fromRight: true)
        sys     = Card(title: "SYSTEM",                 frame: CGRect(x: W/2 - 260, y: B, width: 520, height: 70))
        [cpu, mem, procs, sensors, net, sys].forEach { layer?.addSublayer($0) }

        // Center radar ring (faint)
        let R: CGFloat = 140
        radar.position = CGPoint(x: W/2, y: (H + bottom)/2); radar.bounds = CGRect(x: -R, y: -R, width: 2*R, height: 2*R)
        func ring(_ r: CGFloat, _ w: CGFloat, _ a: CGFloat, dash: [NSNumber]? = nil, e: CGFloat = 1) -> CAShapeLayer {
            let l = CAShapeLayer(); let p = CGMutablePath(); p.addArc(center: .zero, radius: r, startAngle: 0, endAngle: .pi*2, clockwise: false)
            l.path = p; l.fillColor = nil; l.strokeColor = CYAN.withAlphaComponent(a).cgColor; l.lineWidth = w; l.lineDashPattern = dash; l.strokeEnd = e; return l }
        let r1 = ring(R, 1.5, 0.5, e: 0.8), r2 = ring(R-18, 6, 0.2, dash: [2, 10]), r3 = ring(R-40, 1, 0.4, dash: [30, 8]), r4 = ring(R-80, 2, 0.6, e: 0.3)
        [r1, r2, r3, r4].forEach { radar.addSublayer($0) }
        let sp = CGMutablePath(); sp.move(to: .zero); sp.addArc(center: .zero, radius: R-2, startAngle: 0, endAngle: .pi/3, clockwise: false); sp.closeSubpath()
        sweep.path = sp; sweep.fillColor = CYAN.withAlphaComponent(0.12).cgColor; radar.addSublayer(sweep)
        layer?.addSublayer(radar)
        for (l, d, rev) in [(r1, 10.0, false), (r2, 16.0, true), (r3, 24.0, false), (r4, 4.0, true), (sweep, 3.0, false)] {
            let a = CABasicAnimation(keyPath: "transform.rotation.z"); a.toValue = (rev ? -1 : 1) * Double.pi*2; a.duration = d; a.repeatCount = .infinity; l.add(a, forKey: "spin")
        }
        clock.fontSize = 40; clock.font = NSFont.monospacedSystemFont(ofSize: 40, weight: .thin); clock.foregroundColor = CYAN.cgColor
        clock.alignmentMode = .center; clock.contentsScale = 2; clock.frame = CGRect(x: W/2 - 200, y: H - 70, width: 400, height: 50)
        layer?.addSublayer(clock)
        radar.opacity = 0.0
    }

    func show() {
        [cpu, mem, procs, sensors, net, sys].enumerated().forEach { $1!.reveal(delay: 0.08 * Double($0)) }
        CATransaction.begin(); CATransaction.setAnimationDuration(0.8); radar.opacity = 1; CATransaction.commit()
        update(); timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in self.update() }
        DispatchQueue.global().async { Stats.shared.refreshSlow() }
    }
    func stop() { timer?.invalidate() }

    func update() {
        let s = Stats.shared.refresh()
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; clock.string = f.string(from: Date())
        var rows: [(String, Double, String)] = [("TOTAL", s.cpu/100, String(format: "%.0f %%", s.cpu))]
        rows += s.cpuCores.enumerated().map { ("C\($0.offset)", $0.element/100, String(format: "%.0f %%", $0.element)) }
        cpu.setBars(Array(rows.prefix(17)), rowH: 15.5)
        mem.setBars([("MEM", s.memUsed/s.memTotal, String(format: "%.1f/%.0f GB", s.memUsed, s.memTotal)),
                     ("SWAP", min(s.swap/8, 1), String(format: "%.2f GB", s.swap)),
                     ("DISK", s.diskUsed/max(s.diskTotal,1), String(format: "%.0f/%.0f GB", s.diskUsed, s.diskTotal)),
                     ("LOAD", min(s.load.0/Double(max(s.cpuCores.count,1)),1), String(format: "%.2f %.2f %.2f", s.load.0, s.load.1, s.load.2))])
        var sens: [(String, Double, String)] = s.fans.enumerated().map { ("FAN \($0.offset)" + (s.fanManual ? " ●" : ""), $0.element.rpm/max($0.element.max, 1), String(format: "%.0f rpm", $0.element.rpm)) }
        sensors.titleL.string = s.fanManual ? "THERMAL  //  FANS  [MANUAL]" : "THERMAL  //  FANS  [AUTO]"
        sens += s.temps.prefix(22).map { ($0.0, $0.1/100, String(format: "%.1f °C", $0.1)) }
        if sens.isEmpty { sensors.setLines(["No SMC sensors readable."]) } else { sensors.setBars(sens, rowH: 17) }
        var n: [(String, Double, String)] = [("DOWN", min(s.netIn/1.25e7, 1), Stats.fmtBytes(s.netIn) + "/s"), ("UP", min(s.netOut/1.25e7, 1), Stats.fmtBytes(s.netOut) + "/s")]
        if s.battery >= 0 { n.append(("BATT", Double(s.battery)/100, "\(s.battery)%" + (s.charging ? " ⚡" : s.timeLeft > 0 ? "  \(s.timeLeft/60)h\(s.timeLeft%60)m" : ""))) }
        net.setBars(n, rowH: 17)
        procs.setBars(s.procs.prefix(8).map { ($0.0.prefix(9).description, min($0.1/100, 1), String(format: "%.1f %%", $0.1)) }, rowH: 18)
        sys.setLines(["\(s.chip)   ·   macOS \({ let v = ProcessInfo.processInfo.operatingSystemVersion; return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" }())   ·   UP \(Stats.fmtUptime(s.uptime))   ·   THERMAL \(s.thermal.uppercased())",
                      "IP \(s.ip)\(s.wifi.isEmpty || s.wifi.contains("redacted") ? "" : "   ·   WI‑FI \(s.wifi)")   ·   \(Host.current().localizedName ?? "")"])
        if Int(Date().timeIntervalSince1970) % 5 == 0 { DispatchQueue.global().async { Stats.shared.refreshSlow() } }
    }
}

final class OverlayWindow: NSWindow {
    var view: OverlayView
    let screenRef: NSScreen
    var lastInsets = (CGFloat(-1), CGFloat(-1))

    /// A Space is "full-screen" when some normal on-screen window covers the entire screen (menu bar + dock hidden).
    /// Returns the full-screen window's rect (AppKit coords) if the current Space is a full-screen app.
    static func fullScreenWindowRect(_ screen: NSScreen) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let sf = screen.frame; let primaryH = NSScreen.screens.first?.frame.height ?? sf.height
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0, let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let r = CGRect(x: b["X"]!, y: primaryH - b["Y"]! - b["Height"]!, width: b["Width"]!, height: b["Height"]!)
            // full width, (nearly) full height — menu bar may remain visible in full screen on newer macOS
            if abs(r.width - sf.width) < 2 && abs(r.minX - sf.minX) < 2 && r.height >= sf.height - 60 && abs(r.minY - sf.minY) < 2 { return r }
        }
        return nil
    }
    func insets() -> (CGFloat, CGFloat) {
        let f = screenRef.frame
        if let r = OverlayWindow.fullScreenWindowRect(screenRef) { return (f.maxY - r.maxY, 0) }
        let v = screenRef.visibleFrame
        return (f.maxY - v.maxY, v.minY - f.minY)
    }
    func relayout() {
        let i = insets(); guard i != lastInsets else { return }
        lastInsets = i
        view.stop()
        view = OverlayView(frame: NSRect(origin: .zero, size: frame.size), topInset: i.0, bottomInset: i.1)
        contentView = view
        view.show()
    }
    init(screen: NSScreen) {
        screenRef = screen
        view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size), topInset: 0, bottomInset: 0)
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = NSColor(red: 0, green: 0.02, blue: 0.05, alpha: 0.35); level = .floating
        ignoresMouseEvents = true; hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = view
    }
}
