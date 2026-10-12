// Renders the Songtide app icon (a note dropping into a well, sending out ripples) at 1024×1024.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: 824pt squircle centred on the 1024 canvas, with a soft drop shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    color(0x0B0F2A).setFill()
    squircle.fill()
    ctx.restoreGState()

    ctx.saveGState()
    squircle.addClip()
    // Deep violet → night.
    NSGradient(colors: [color(0x3A1F6E), color(0x1A1540), color(0x080B1F)], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
        .draw(in: tile, angle: 90) // flipped context: 90° runs top → bottom
    // Warm glow where the note lands.
    let wellCenter = CGPoint(x: 512, y: 690)
    NSGradient(colors: [color(0xFF6A4D, 0.55), color(0xFF3D6E, 0.18), color(0xFF3D6E, 0)], atLocations: [0, 0.45, 1], colorSpace: .sRGB)!
        .draw(fromCenter: wellCenter, radius: 0, toCenter: wellCenter, radius: 420, options: [])

    // Ripples: broken, brush-like arcs that swell in the middle and taper to points, like rings
    // spreading across water. Each ring has a longer front arc and a shorter back arc.
    func taperedArc(center: CGPoint, rx: CGFloat, ry: CGFloat, from start: CGFloat, to end: CGFloat, width: CGFloat) -> NSBezierPath {
        let steps = 120
        var outer: [CGPoint] = [], inner: [CGPoint] = []
        for i in 0...steps {
            let t = start + (end - start) * CGFloat(i) / CGFloat(steps)
            let a = t * .pi / 180
            let point = CGPoint(x: center.x + rx * cos(a), y: center.y + ry * sin(a))
            // Outward normal of the ellipse at this point.
            var n = CGVector(dx: cos(a) / rx, dy: sin(a) / ry)
            let len = sqrt(n.dx * n.dx + n.dy * n.dy)
            n = CGVector(dx: n.dx / len, dy: n.dy / len)
            let half = width / 2 * sin(.pi * CGFloat(i) / CGFloat(steps)) // taper to points at both ends
            outer.append(CGPoint(x: point.x + n.dx * half, y: point.y + n.dy * half))
            inner.append(CGPoint(x: point.x - n.dx * half, y: point.y - n.dy * half))
        }
        let path = NSBezierPath()
        path.move(to: outer[0])
        outer.dropFirst().forEach { path.line(to: $0) }
        inner.reversed().forEach { path.line(to: $0) }
        path.close()
        return path
    }

    // (x offset, rx, ry, stroke width, opacity, front arc, back arc) in degrees; 0° is the right,
    // 90° the front. Rings are nested slightly off-centre so their ends stagger like real ripples.
    let rings: [(dx: CGFloat, rx: CGFloat, ry: CGFloat, width: CGFloat, alpha: CGFloat, front: (CGFloat, CGFloat), back: (CGFloat, CGFloat))] = [
        (8, 138, 40, 28, 1.0, (-14, 200), (212, 330)),
        (-6, 240, 70, 22, 0.8, (0, 192), (220, 318)),
        (-22, 334, 100, 16, 0.55, (12, 178), (230, 304)),
    ]
    for ring in rings {
        let center = CGPoint(x: wellCenter.x + ring.dx, y: wellCenter.y)
        for arc in [ring.front, ring.back] {
            let path = taperedArc(center: center, rx: ring.rx, ry: ring.ry, from: arc.0, to: arc.1,
                                  width: arc == ring.back ? ring.width * 0.75 : ring.width)
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 16, color: color(0xFF6A4D, ring.alpha * 0.8).cgColor)
            color(0xFF8A5B, ring.alpha).setFill()
            path.fill()
            ctx.restoreGState()
        }
    }

    // The note: an eighth note whose head is just touching the water, built as one merged outline.
    let headCenter = CGPoint(x: wellCenter.x + 8, y: wellCenter.y - 62) // sits on the innermost ripple, behind its front arc
    let semiX: CGFloat = 90, semiY: CGFloat = 64, tilt: CGFloat = -22 * .pi / 180
    let head = NSBezierPath(ovalIn: CGRect(x: -semiX, y: -semiY, width: semiX * 2, height: semiY * 2))
    var t = AffineTransform(translationByX: headCenter.x, byY: headCenter.y)
    t.rotate(byRadians: tilt)
    head.transform(using: t)

    // Where the tilted head's outline is furthest right, it runs straight up and down: put the
    // stem's right edge exactly there so the stem flows into the head without a corner.
    var rightmost = CGPoint(x: -.infinity, y: 0)
    for step in 0..<3600 {
        let a = CGFloat(step) / 3600 * 2 * .pi
        let x = semiX * cos(a), y = semiY * sin(a)
        let p = CGPoint(x: headCenter.x + x * cos(tilt) - y * sin(tilt), y: headCenter.y + x * sin(tilt) + y * cos(tilt))
        if p.x > rightmost.x { rightmost = p }
    }
    let stemWidth: CGFloat = 36
    let stemRight = rightmost.x
    let top: CGFloat = headCenter.y - 382
    // Rounded top; the bottom ends well inside the head.
    let stem = NSBezierPath(roundedRect: CGRect(x: stemRight - stemWidth, y: top, width: stemWidth, height: rightmost.y + 30 - top),
                            xRadius: stemWidth / 2, yRadius: stemWidth / 2)

    // Flag: leaves the top of the stem, bulges out to the right, then sweeps down and in to a point.
    func f(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint { CGPoint(x: stemRight + dx, y: top + dy) }
    let flag = NSBezierPath()
    flag.move(to: f(-stemWidth / 2, 0))
    flag.line(to: f(0, 14))
    flag.curve(to: f(104, 176), controlPoint1: f(30, 56), controlPoint2: f(106, 92))
    flag.curve(to: f(68, 296), controlPoint1: f(106, 226), controlPoint2: f(88, 270))
    flag.curve(to: f(0, 144), controlPoint1: f(90, 230), controlPoint2: f(58, 164))
    flag.line(to: f(-stemWidth / 2, 144))
    flag.close()

    let merged = head.cgPath.union(stem.cgPath).union(flag.cgPath)
    let note = NSBezierPath(cgPath: merged)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 30, color: color(0xFF4D6D, 0.55).cgColor)
    note.addClip()
    NSGradient(colors: [color(0xFFFFFF), color(0xFFE3D6), color(0xFFB199)], atLocations: [0, 0.6, 1], colorSpace: .sRGB)!
        .draw(in: note.bounds, angle: -90)
    ctx.restoreGState()

    // Subtle top highlight on the tile for depth.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.10), NSColor.white.withAlphaComponent(0)], atLocations: [0, 1], colorSpace: .sRGB)!
        .draw(in: CGRect(x: tile.minX, y: tile.minY, width: tile.width, height: 300), angle: 90)
    ctx.restoreGState()

    // Hairline edge.
    let edge = NSBezierPath(roundedRect: tile.insetBy(dx: 1, dy: 1), xRadius: 184, yRadius: 184)
    edge.lineWidth = 2
    NSColor.white.withAlphaComponent(0.08).setStroke()
    edge.stroke()
    return true
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: size, height: size)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
