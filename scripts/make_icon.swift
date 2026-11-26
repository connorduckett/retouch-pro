// Draws the Retouch Pro app icon (grayscale aperture on a soft tile) and writes an .iconset.
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func hex(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

func draw(size: Int) -> CGImage {
    let s = CGFloat(size)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // macOS icon grid: ~10% inset, continuous corners
    let inset = s * 0.1
    let tile = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = CGPath(roundedRect: tile, cornerWidth: tile.width * 0.225, cornerHeight: tile.width * 0.225, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: hex(0x000000, 0.3))
    ctx.addPath(path); ctx.setFillColor(hex(0xF8F8F8)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let bg = CGGradient(colorsSpace: cs, colors: [hex(0xF8F8F8), hex(0xE2E2E2)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

    // Lens body
    let c = CGPoint(x: tile.midX, y: tile.midY)
    let R = tile.width * 0.34
    ctx.setFillColor(hex(0x6A6A6A))
    ctx.fillEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2))
    ctx.setFillColor(hex(0x979797))
    let r2 = R * 0.82
    ctx.fillEllipse(in: CGRect(x: c.x - r2, y: c.y - r2, width: r2 * 2, height: r2 * 2))

    // Aperture blades
    let blades = 6
    let r3 = R * 0.74
    for i in 0..<blades {
        let a0 = CGFloat(i) / CGFloat(blades) * 2 * .pi + .pi / 12
        let a1 = a0 + 2 * .pi / CGFloat(blades)
        let p = CGMutablePath()
        p.move(to: c)
        p.addLine(to: CGPoint(x: c.x + cos(a0) * r3, y: c.y + sin(a0) * r3))
        p.addLine(to: CGPoint(x: c.x + cos(a1) * r3, y: c.y + sin(a1) * r3))
        p.closeSubpath()
        let shades: [UInt32] = [0xBDBDBD, 0xE2E2E2, 0xBDBDBD, 0x979797, 0xBDBDBD, 0xE2E2E2]
        ctx.addPath(p); ctx.setFillColor(hex(shades[i])); ctx.fillPath()
        ctx.addPath(p); ctx.setStrokeColor(hex(0x6A6A6A)); ctx.setLineWidth(max(1, s * 0.006)); ctx.strokePath()
    }
    // Hexagonal opening
    let r4 = R * 0.3
    let hexPath = CGMutablePath()
    for i in 0..<6 {
        let a = CGFloat(i) / 6 * 2 * .pi + .pi / 6
        let pt = CGPoint(x: c.x + cos(a) * r4, y: c.y + sin(a) * r4)
        if i == 0 { hexPath.move(to: pt) } else { hexPath.addLine(to: pt) }
    }
    hexPath.closeSubpath()
    ctx.addPath(hexPath); ctx.setFillColor(hex(0x3D3D3D)); ctx.fillPath()

    // Sparkle (retouch)
    let sp = CGPoint(x: tile.maxX - tile.width * 0.17, y: tile.maxY - tile.width * 0.17)
    let L = tile.width * 0.09, w = L * 0.28
    let star = CGMutablePath()
    star.move(to: CGPoint(x: sp.x, y: sp.y + L))
    star.addQuadCurve(to: CGPoint(x: sp.x + L, y: sp.y), control: CGPoint(x: sp.x + w, y: sp.y + w))
    star.addQuadCurve(to: CGPoint(x: sp.x, y: sp.y - L), control: CGPoint(x: sp.x + w, y: sp.y - w))
    star.addQuadCurve(to: CGPoint(x: sp.x - L, y: sp.y), control: CGPoint(x: sp.x - w, y: sp.y - w))
    star.addQuadCurve(to: CGPoint(x: sp.x, y: sp.y + L), control: CGPoint(x: sp.x - w, y: sp.y + w))
    ctx.addPath(star); ctx.setFillColor(hex(0x6A6A6A)); ctx.fillPath()
    ctx.restoreGState()

    return ctx.makeImage()!
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let rep = NSBitmapImageRep(cgImage: draw(size: px))
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out + "/" + name))
    }
}
