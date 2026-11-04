// Renders the app icon PNGs and the DMG background. Usage: swift render.swift <outdir>
import Cocoa

let out = CommandLine.arguments[1]
let cyan = NSColor(red: 0.30, green: 0.85, blue: 1.0, alpha: 1)
let deep = NSColor(red: 0.02, green: 0.07, blue: 0.12, alpha: 1)

func image(_ w: CGFloat, _ h: CGFloat, _ draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w), pixelsHigh: Int(h), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!; NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
    draw(ctx.cgContext); NSGraphicsContext.restoreGraphicsState(); return rep
}
func save(_ rep: NSBitmapImageRep, _ name: String) { try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out + "/" + name)) }

/// The JARVIS reactor: dotted outer ring, two arcs, inner dashed ring, glowing core. `s` = size of the square it fills.
func reactor(_ g: CGContext, center c: CGPoint, size s: CGFloat, glow: Bool = true) {
    let r = s / 2
    g.saveGState()
    if glow { g.setShadow(offset: .zero, blur: s * 0.06, color: cyan.withAlphaComponent(0.9).cgColor) }
    // outer dotted ring
    g.setFillColor(cyan.withAlphaComponent(0.55).cgColor)
    for i in 0..<36 { let a = CGFloat(i) / 36 * .pi * 2; let p = CGPoint(x: c.x + cos(a) * r * 0.92, y: c.y + sin(a) * r * 0.92); let d = s * 0.035
        g.fillEllipse(in: CGRect(x: p.x - d, y: p.y - d, width: d * 2, height: d * 2)) }
    // two bright arcs
    g.setStrokeColor(cyan.cgColor); g.setLineWidth(s * 0.035); g.setLineCap(.round)
    g.addArc(center: c, radius: r * 0.76, startAngle: .pi * 0.15, endAngle: .pi * 0.85, clockwise: false); g.strokePath()
    g.addArc(center: c, radius: r * 0.76, startAngle: .pi * 1.15, endAngle: .pi * 1.65, clockwise: false); g.strokePath()
    // inner dashed ring
    g.setLineWidth(s * 0.02); g.setLineDash(phase: 0, lengths: [s * 0.05, s * 0.035])
    g.addArc(center: c, radius: r * 0.52, startAngle: 0, endAngle: .pi * 2, clockwise: false); g.strokePath()
    g.setLineDash(phase: 0, lengths: [])
    // core
    let core = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [NSColor.white.cgColor, cyan.cgColor, cyan.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 0.45, 1])!
    g.drawRadialGradient(core, startCenter: c, startRadius: 0, endCenter: c, endRadius: r * 0.36, options: [])
    g.restoreGState()
}

// ---- App icon (macOS rounded square) ----
let sizes: [(Int, Int)] = [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)]
for (pt, scale) in sizes {
    let px = CGFloat(pt * scale)
    let rep = image(px, px) { g in
        let inset = px * 0.08, rr = px * 0.19   // Apple's icon grid: ~82% square, continuous corners
        let sq = CGRect(x: inset, y: inset, width: px - inset * 2, height: px - inset * 2)
        let path = CGPath(roundedRect: sq, cornerWidth: rr, cornerHeight: rr, transform: nil)
        g.saveGState(); g.setShadow(offset: CGSize(width: 0, height: -px * 0.01), blur: px * 0.03, color: NSColor.black.withAlphaComponent(0.5).cgColor)
        g.addPath(path); g.setFillColor(deep.cgColor); g.fillPath(); g.restoreGState()
        g.saveGState(); g.addPath(path); g.clip()
        let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [NSColor(red: 0.05, green: 0.16, blue: 0.26, alpha: 1).cgColor, deep.cgColor] as CFArray, locations: [0, 1])!
        g.drawRadialGradient(bg, startCenter: CGPoint(x: px / 2, y: px * 0.58), startRadius: 0, endCenter: CGPoint(x: px / 2, y: px / 2), endRadius: px * 0.7, options: [])
        // faint HUD grid
        g.setStrokeColor(cyan.withAlphaComponent(0.07).cgColor); g.setLineWidth(max(1, px * 0.003))
        var x = sq.minX; while x < sq.maxX { g.move(to: CGPoint(x: x, y: sq.minY)); g.addLine(to: CGPoint(x: x, y: sq.maxY)); x += px * 0.1 }
        var y = sq.minY; while y < sq.maxY { g.move(to: CGPoint(x: sq.minX, y: y)); g.addLine(to: CGPoint(x: sq.maxX, y: y)); y += px * 0.1 }
        g.strokePath()
        reactor(g, center: CGPoint(x: px / 2, y: px / 2), size: px * 0.62, glow: px >= 64)
        g.restoreGState()
        // subtle rim
        g.addPath(path); g.setStrokeColor(cyan.withAlphaComponent(0.35).cgColor); g.setLineWidth(max(1, px * 0.006)); g.strokePath()
    }
    save(rep, "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png")
}

// ---- DMG background. Designed for a 660x400 window, but rendered 1400x900 with the same dark fill around it,
// because recent Finder versions ignore the saved window size and would otherwise show white past the image edge.
for scale in [1, 2] {
    let k = CGFloat(scale), W: CGFloat = 1400 * k, H: CGFloat = 900 * k, dw: CGFloat = 660 * k, dh: CGFloat = 400 * k
    let rep = image(W, H) { g in
        g.setFillColor(deep.cgColor); g.fill(CGRect(x: 0, y: 0, width: W, height: H))
        // flip so y grows downwards like Finder coordinates; design occupies the top-left dw x dh
        g.translateBy(x: 0, y: H); g.scaleBy(x: 1, y: -1)
        let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [NSColor(red: 0.04, green: 0.12, blue: 0.20, alpha: 1).cgColor, deep.cgColor] as CFArray, locations: [0, 1])!
        g.drawRadialGradient(bg, startCenter: CGPoint(x: dw / 2, y: dh * 0.45), startRadius: 0, endCenter: CGPoint(x: dw / 2, y: dh / 2), endRadius: dw * 0.75, options: [])
        g.setStrokeColor(cyan.withAlphaComponent(0.06).cgColor); g.setLineWidth(1)
        var x: CGFloat = 0; while x < W { g.move(to: CGPoint(x: x, y: 0)); g.addLine(to: CGPoint(x: x, y: H)); x += 40 * k }
        var y: CGFloat = 0; while y < H { g.move(to: CGPoint(x: 0, y: y)); g.addLine(to: CGPoint(x: W, y: y)); y += 40 * k }
        g.strokePath()
        g.saveGState(); g.setAlpha(0.12); reactor(g, center: CGPoint(x: dw / 2, y: dh * 0.5), size: dh * 1.3, glow: false); g.restoreGState()
        // Finder draws icon labels black on this art; give each label a pale plate (icons at x=165/495, y=200, size 128)
        for cx in [165 * k, 495 * k] {
            let plate = CGRect(x: cx - 60 * k, y: 200 * k + 70 * k, width: 120 * k, height: 22 * k)
            g.setFillColor(NSColor(red: 0.80, green: 0.93, blue: 1.0, alpha: 0.88).cgColor)
            g.addPath(CGPath(roundedRect: plate, cornerWidth: 6 * k, cornerHeight: 6 * k, transform: nil)); g.fillPath()
        }
        // arrow between the icons
        g.setStrokeColor(cyan.cgColor); g.setLineWidth(5 * k); g.setLineCap(.round); g.setLineJoin(.round)
        g.setShadow(offset: .zero, blur: 10 * k, color: cyan.cgColor)
        let ay = 200 * k, x0 = 265 * k, x1 = 395 * k
        g.setLineDash(phase: 0, lengths: [14 * k, 12 * k]); g.move(to: CGPoint(x: x0, y: ay)); g.addLine(to: CGPoint(x: x1 - 28 * k, y: ay)); g.strokePath()
        g.setLineDash(phase: 0, lengths: [])
        g.move(to: CGPoint(x: x1 - 26 * k, y: ay + 18 * k)); g.addLine(to: CGPoint(x: x1, y: ay)); g.addLine(to: CGPoint(x: x1 - 26 * k, y: ay - 18 * k)); g.strokePath()
        g.setShadow(offset: .zero, blur: 0, color: nil)
        // text (drawn un-flipped)
        func text(_ s: String, _ pt: CGFloat, _ yTop: CGFloat, _ color: NSColor, _ weight: NSFont.Weight = .regular, kern: CGFloat = 0) {
            let f = NSFont.monospacedSystemFont(ofSize: pt * k, weight: weight)
            let a = NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: color, .kern: kern * k])
            let sz = a.size()
            g.saveGState(); g.translateBy(x: 0, y: H); g.scaleBy(x: 1, y: -1)
            a.draw(at: CGPoint(x: (dw - sz.width) / 2, y: H - yTop * k - sz.height)); g.restoreGState()
        }
        text("J.A.R.V.I.S.", 30, 42, cyan, .semibold, kern: 6)
        text("Drag the reactor into Applications, sir.", 13, 92, cyan.withAlphaComponent(0.75))
        text("menu bar  ◎  ·  ⌥ Space to summon  ·  say \"Jarvis\"", 11, 346, cyan.withAlphaComponent(0.45))
    }
    save(rep, scale == 2 ? "dmg-bg@2x.png" : "dmg-bg.png")
}
print("ok")
