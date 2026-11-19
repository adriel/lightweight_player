// Renders LightPlayer's app icon and document icons (1024 masters + iconsets).
// usage: swift Tools/icons/render.swift <outDir>
import AppKit
import CoreGraphics

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icons-out", isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let cs = CGColorSpace(name: CGColorSpace.displayP3)!

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat((hex >> 16) & 0xff) / 255, CGFloat((hex >> 8) & 0xff) / 255, CGFloat(hex & 0xff) / 255, a])!
}

func render(_ size: Int, _ draw: (CGContext, CGFloat) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let s = CGFloat(size) / 1024
    ctx.scaleBy(x: s, y: s)
    draw(ctx, s)
    return ctx.makeImage()!
}

func save(_ img: CGImage, _ url: URL) {
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

/// macOS-style squircle (continuous corners).
func squircle(_ r: CGRect, radius: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.addRoundedRect(in: r, cornerWidth: radius, cornerHeight: radius)
    return p
}

/// Rounded play triangle (pointing right), centred optically in `r`.
func playTriangle(in r: CGRect, cornerRadius cr: CGFloat) -> CGPath {
    let h = r.height, w = h * 0.92
    let x0 = r.midX - w * 0.40, y0 = r.midY - h / 2
    let a = CGPoint(x: x0, y: y0), b = CGPoint(x: x0, y: y0 + h), c = CGPoint(x: x0 + w, y: r.midY)
    let p = CGMutablePath()
    p.move(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
    p.addArc(tangent1End: b, tangent2End: c, radius: cr)
    p.addArc(tangent1End: c, tangent2End: a, radius: cr)
    p.addArc(tangent1End: a, tangent2End: b, radius: cr)
    p.closeSubpath()
    return p
}

/// The LightPlayer mark: night-blue squircle, lens ring, glowing play triangle. Drawn into `rect` (any size).
func drawMark(_ ctx: CGContext, in rect: CGRect, shadow: Bool) {
    let k = rect.width / 824
    let radius = 185 * k
    let body = squircle(rect, radius: radius)
    if shadow {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -14 * k), blur: 28 * k, color: color(0x000000, 0.35))
        ctx.addPath(body); ctx.setFillColor(color(0x0B1026)); ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.addPath(body); ctx.clip()
    // Background: deep night blue → indigo, diagonal.
    let bg = CGGradient(colorsSpace: cs, colors: [color(0x1B1F4A), color(0x0A0E24)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    // Soft light bloom behind the glyph.
    let c = CGPoint(x: rect.midX, y: rect.midY)
    let bloom = CGGradient(colorsSpace: cs, colors: [color(0x5B8CFF, 0.55), color(0x6A4CFF, 0.18), color(0x6A4CFF, 0)] as CFArray, locations: [0, 0.45, 1])!
    ctx.drawRadialGradient(bloom, startCenter: c, startRadius: 0, endCenter: c, endRadius: 430 * k, options: [])
    // Lens ring.
    ctx.setLineWidth(18 * k)
    let ringR = 285 * k
    ctx.addEllipse(in: CGRect(x: c.x - ringR, y: c.y - ringR, width: ringR * 2, height: ringR * 2))
    ctx.replacePathWithStrokedPath(); ctx.clip()
    let ring = CGGradient(colorsSpace: cs, colors: [color(0x9FE8FF, 0.85), color(0x7A6CFF, 0.35)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(ring, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    ctx.restoreGState()

    // Glowing play triangle.
    let tri = playTriangle(in: CGRect(x: c.x - 170 * k, y: c.y - 185 * k, width: 340 * k, height: 370 * k), cornerRadius: 46 * k)
    ctx.saveGState()
    ctx.addPath(body); ctx.clip()
    ctx.setShadow(offset: .zero, blur: 70 * k, color: color(0x7FD8FF, 0.9))
    ctx.addPath(tri); ctx.setFillColor(color(0xBFEFFF)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tri); ctx.clip()
    let fill = CGGradient(colorsSpace: cs, colors: [color(0xFFFFFF), color(0xBDEBFF), color(0x8FA2FF)] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(fill, start: CGPoint(x: c.x - 150 * k, y: c.y + 190 * k), end: CGPoint(x: c.x + 170 * k, y: c.y - 190 * k), options: [])
    ctx.restoreGState()
    // Top sheen + hairline rim.
    ctx.saveGState()
    ctx.addPath(body); ctx.clip()
    let sheen = CGGradient(colorsSpace: cs, colors: [color(0xFFFFFF, 0.10), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.midY), options: [])
    ctx.restoreGState()
    ctx.addPath(squircle(rect.insetBy(dx: 1.5 * k, dy: 1.5 * k), radius: radius))
    ctx.setStrokeColor(color(0xFFFFFF, 0.14)); ctx.setLineWidth(3 * k); ctx.strokePath()
}

func appIcon(_ ctx: CGContext, _ s: CGFloat) {
    drawMark(ctx, in: CGRect(x: 100, y: 100, width: 824, height: 824), shadow: true)
}

/// Document icon: folded page, the mark, and a coloured format label.
func docIcon(label: String, tint: UInt32) -> (CGContext, CGFloat) -> Void {
    return { ctx, _ in
        let page = CGRect(x: 190, y: 64, width: 644, height: 896)
        let fold: CGFloat = 170, r: CGFloat = 34
        let p = CGMutablePath()
        p.move(to: CGPoint(x: page.minX + r, y: page.minY))
        p.addArc(tangent1End: CGPoint(x: page.maxX, y: page.minY), tangent2End: CGPoint(x: page.maxX, y: page.maxY), radius: r)
        p.addLine(to: CGPoint(x: page.maxX, y: page.maxY - fold))
        p.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY))
        p.addArc(tangent1End: CGPoint(x: page.minX, y: page.maxY), tangent2End: CGPoint(x: page.minX, y: page.minY), radius: r)
        p.addArc(tangent1End: CGPoint(x: page.minX, y: page.minY), tangent2End: CGPoint(x: page.maxX, y: page.minY), radius: r)
        p.closeSubpath()
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: color(0x000000, 0.28))
        ctx.addPath(p); ctx.setFillColor(color(0xFFFFFF)); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState(); ctx.addPath(p); ctx.clip()
        let paper = CGGradient(colorsSpace: cs, colors: [color(0xFFFFFF), color(0xEEF0F6)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(paper, start: CGPoint(x: 0, y: page.maxY), end: CGPoint(x: 0, y: page.minY), options: [])
        ctx.restoreGState()
        ctx.addPath(p); ctx.setStrokeColor(color(0x000000, 0.12)); ctx.setLineWidth(3); ctx.strokePath()
        // Folded corner.
        let f = CGMutablePath()
        f.move(to: CGPoint(x: page.maxX - fold, y: page.maxY))
        f.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY - fold + 24))
        f.addArc(tangent1End: CGPoint(x: page.maxX - fold, y: page.maxY - fold), tangent2End: CGPoint(x: page.maxX, y: page.maxY - fold), radius: 24)
        f.addLine(to: CGPoint(x: page.maxX, y: page.maxY - fold))
        f.closeSubpath()
        ctx.addPath(f); ctx.setFillColor(color(0xD9DDE8)); ctx.fillPath()
        ctx.addPath(f); ctx.setStrokeColor(color(0x000000, 0.10)); ctx.setLineWidth(3); ctx.strokePath()
        // The mark.
        drawMark(ctx, in: CGRect(x: 512 - 175, y: 430, width: 350, height: 350), shadow: false)
        // Format label.
        let pill = CGRect(x: page.minX + 70, y: page.minY + 90, width: page.width - 140, height: 170)
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 40, cornerHeight: 40, transform: nil)); ctx.setFillColor(color(tint)); ctx.fillPath()
        let font = NSFont.systemFont(ofSize: label.count > 3 ? 118 : 138, weight: .heavy)
        let str = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: NSColor.white, .kern: 4])
        let line = CTLineCreateWithAttributedString(str)
        let b = CTLineGetImageBounds(line, ctx)
        ctx.textPosition = CGPoint(x: pill.midX - b.width / 2 - b.minX, y: pill.midY - b.height / 2 - b.minY)
        CTLineDraw(line, ctx)
    }
}

func iconset(_ name: String, _ draw: @escaping (CGContext, CGFloat) -> Void) {
    let dir = out.appendingPathComponent("\(name).iconset", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        save(render(base, draw), dir.appendingPathComponent("icon_\(base)x\(base).png"))
        save(render(base * 2, draw), dir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
    }
    save(render(1024, draw), out.appendingPathComponent("\(name).png"))
}

iconset("AppIcon", appIcon)
let docs: [(String, String, UInt32)] = [
    ("doc-mkv", "MKV", 0x8E5CF7), ("doc-mp4", "MP4", 0x2D7FF9), ("doc-m4v", "M4V", 0x5856D6), ("doc-mov", "MOV", 0x12A79D),
    ("doc-webm", "WEBM", 0x2FB350), ("doc-avi", "AVI", 0xF08A00), ("doc-ts", "TS", 0xE5453A), ("doc-flv", "FLV", 0xE03A8A),
    ("doc-video", "VIDEO", 0x6E7381),
]
for (name, label, tint) in docs { iconset(name, docIcon(label: label, tint: tint)) }
print("ok")
