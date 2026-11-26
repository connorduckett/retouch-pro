import AppKit
import CoreImage
import ImageIO

/// Renders adjustment layers, layer masks, text, shapes and pen paths.
enum LayerRenderer {
    struct Context {
        /// Size of the source image used for this render (proxy or full).
        var sourceSize: CGSize
        var geometry: ImagePipeline.Geometry
        /// Output (cropped) extent, origin at zero.
        var extent: CGRect

        var sourceScale: CGFloat { max(sourceSize.width, sourceSize.height) }
        /// Shorter side of the output frame; text and stroke sizes are relative to it.
        var frameShort: CGFloat { min(extent.width, extent.height) }

        /// Moves an image drawn in source coordinates into output coordinates.
        func toOutput(_ img: CIImage) -> CIImage {
            img.transformed(by: geometry.transform)
                .cropped(to: geometry.crop)
                .transformed(by: CGAffineTransform(translationX: -geometry.crop.minX, y: -geometry.crop.minY))
        }

        /// Frame-normalized (top-left origin) → output pixels (bottom-left origin).
        func px(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x * extent.width, y: (1 - p.y) * extent.height)
        }

        func pxRect(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX * extent.width, y: (1 - r.maxY) * extent.height,
                   width: r.width * extent.width, height: r.height * extent.height)
        }
    }

    // MARK: Compositing

    static func apply(_ layer: Layer, to base: CIImage, _ ctx: Context) -> CIImage {
        let extent = ctx.extent
        var mask = mask(for: layer, ctx)
        if layer.opacity < 100 {
            let o = layer.opacity / 100
            let m = mask ?? CIImage(color: .white).cropped(to: extent)
            mask = m.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: o, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: o, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: o, w: 0),
            ])
        }

        switch layer.kind {
        case .adjustment:
            guard !layer.adjustments.isIdentity else { return base }
            var adjusted = ImagePipeline.applyTone(base, layer.adjustments, extent: extent)
            adjusted = ImagePipeline.applyEffects(adjusted, layer.adjustments, extent: extent)
            guard let mask else { return adjusted }
            return adjusted.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: base,
                kCIInputMaskImageKey: mask,
            ]).cropped(to: extent)

        case .text, .shape, .path:
            guard var content = contentImage(layer, ctx) else { return base }
            if let mask {
                content = content.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: CIImage.empty(),
                    kCIInputMaskImageKey: mask,
                ])
            }
            if let blend = layer.blend.filterName {
                // Blend modes don't respect transparency on their own: blend, then keep only where content is.
                let blended = content.applyingFilter(blend, parameters: [kCIInputBackgroundImageKey: base])
                let alpha = content.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                    "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                ]).cropped(to: extent)
                return blended.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: base,
                    kCIInputMaskImageKey: alpha,
                ]).cropped(to: extent)
            }
            return content.composited(over: base).cropped(to: extent)
        }
    }

    /// Red overlay showing where a mask applies.
    static func maskOverlay(_ mask: CIImage, over img: CIImage, extent: CGRect) -> CIImage {
        let red = CIImage(color: CIColor(red: 0.95, green: 0.2, blue: 0.25, alpha: 1)).cropped(to: extent)
        let m = mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.5, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0.5, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0.5, w: 0),
        ])
        return red.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: img,
            kCIInputMaskImageKey: m,
        ]).cropped(to: extent)
    }

    // MARK: Masks

    /// Grayscale mask in output coordinates, or nil when the layer applies everywhere.
    static func mask(for layer: Layer, _ ctx: Context) -> CIImage? {
        let m = layer.mask
        let s = ctx.sourceScale
        let sourceRect = CGRect(origin: .zero, size: ctx.sourceSize)
        var img: CIImage

        switch m.mode {
        case .none:
            return nil
        case .people, .sky, .subject, .background:
            guard let png = m.autoMaskPNG, let base = decodeMask(png) else { return CIImage(color: .black).cropped(to: ctx.extent) }
            // Brush strokes refine the automatic selection.
            img = brushMask(m.strokes, sourceSize: ctx.sourceSize, scale: s, base: base)
            let feather = m.feather / 100 * s * 0.008
            if feather > 0.5 {
                img = img.clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: feather])
                    .cropped(to: sourceRect)
            }
        case .brush:
            img = brushMask(m.strokes, sourceSize: ctx.sourceSize, scale: s)
            let feather = m.feather / 100 * s * 0.02
            if feather > 0.5 {
                img = img.clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: feather])
                    .cropped(to: sourceRect)
            }
        case .linear:
            let p0 = CGPoint(x: m.start[0] * s, y: m.start[1] * s)
            let p1 = CGPoint(x: m.end[0] * s, y: m.end[1] * s)
            img = CIFilter(name: "CISmoothLinearGradient", parameters: [
                "inputPoint0": CIVector(x: p0.x, y: p0.y),
                "inputPoint1": CIVector(x: p1.x, y: p1.y),
                "inputColor0": CIColor.white,
                "inputColor1": CIColor.black,
            ])!.outputImage!.cropped(to: sourceRect)
        case .radial:
            let soft = max(0.02, min(0.98, m.feather / 100))
            let unit = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: 0, y: 0),
                "inputRadius0": 1 - soft,
                "inputRadius1": 1.0,
                "inputColor0": CIColor.white,
                "inputColor1": CIColor.black,
            ])!.outputImage!
            img = unit
                .transformed(by: CGAffineTransform(scaleX: max(1, m.radiusX * s), y: max(1, m.radiusY * s)))
                .transformed(by: CGAffineTransform(translationX: m.center[0] * s, y: m.center[1] * s))
                .cropped(to: sourceRect)
        }

        var out = ctx.toOutput(img)
        // Make sure areas outside the source are black, not transparent.
        out = out.composited(over: CIImage(color: .black).cropped(to: ctx.extent)).cropped(to: ctx.extent)
        if m.inverted {
            out = out.applyingFilter("CIColorInvert").cropped(to: ctx.extent)
        }
        return out
    }

    private static let maskLock = NSLock()
    private static var decodedMasks: [Int: CGImage] = [:]

    private static func decodeMask(_ png: Data) -> CGImage? {
        let key = png.hashValue ^ png.count
        maskLock.lock()
        if let hit = decodedMasks[key] { maskLock.unlock(); return hit }
        maskLock.unlock()
        guard let src = CGImageSourceCreateWithData(png as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        maskLock.lock()
        if decodedMasks.count > 16 { decodedMasks.removeAll() }
        decodedMasks[key] = cg
        maskLock.unlock()
        return cg
    }

    private static func brushMask(_ strokes: [MaskStroke], sourceSize: CGSize, scale: CGFloat,
                                  base: CGImage? = nil) -> CIImage {
        let k = min(1, 2048 / max(sourceSize.width, sourceSize.height))
        let w = max(1, Int(sourceSize.width * k)), h = max(1, Int(sourceSize.height * k))
        let gray = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return CIImage.empty() }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        if let base {
            ctx.interpolationQuality = .high
            ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for stroke in strokes {
            let v: CGFloat = stroke.erase ? 0 : 1
            ctx.setStrokeColor(gray: v, alpha: 1)
            ctx.setFillColor(gray: v, alpha: 1)
            let r = stroke.radius * scale * k
            let pts = stroke.points.compactMap { p -> CGPoint? in
                p.count == 2 ? CGPoint(x: p[0] * scale * k, y: p[1] * scale * k) : nil
            }
            if pts.count == 1 {
                ctx.fillEllipse(in: CGRect(x: pts[0].x - r, y: pts[0].y - r, width: r * 2, height: r * 2))
            } else if pts.count > 1 {
                ctx.setLineWidth(r * 2)
                ctx.addLines(between: pts)
                ctx.strokePath()
            }
        }
        guard let cg = ctx.makeImage() else { return CIImage.empty() }
        return CIImage(cgImage: cg)
            .transformed(by: CGAffineTransform(scaleX: sourceSize.width / CGFloat(w), y: sourceSize.height / CGFloat(h)))
    }

    // MARK: Content layers (text, shapes, paths)

    private static let cacheLock = NSLock()
    private static var cache: [String: (CGImage, CGRect)] = [:]
    private static var cacheOrder: [String] = []

    /// Rasterizes the layer's content (cached) and positions it in output coordinates.
    static func contentImage(_ layer: Layer, _ ctx: Context) -> CIImage? {
        var keyLayer = layer
        keyLayer.mask = LayerMask()
        keyLayer.opacity = 100
        keyLayer.visible = true
        keyLayer.blend = .normal
        let keyData = (try? JSONEncoder().encode(keyLayer)) ?? Data()
        let key = "\(keyData.hashValue)-\(Int(ctx.extent.width))x\(Int(ctx.extent.height))"

        cacheLock.lock()
        let hit = cache[key]
        cacheLock.unlock()
        let entry: (CGImage, CGRect)
        if let hit {
            entry = hit
        } else {
            guard let drawn = draw(layer, ctx) else { return nil }
            entry = drawn
            cacheLock.lock()
            cache[key] = drawn
            cacheOrder.append(key)
            if cacheOrder.count > 24 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
            cacheLock.unlock()
        }
        return CIImage(cgImage: entry.0)
            .transformed(by: CGAffineTransform(translationX: entry.1.minX, y: entry.1.minY))
    }

    /// Draws the layer into a bitmap covering just its bounds. Returns the image and its output-space rect.
    private static func draw(_ layer: Layer, _ ctx: Context) -> (CGImage, CGRect)? {
        let short = ctx.frameShort
        let strokeW = layer.strokeEnabled ? layer.strokeWidth / 100 * short : 0
        var bounds: CGRect
        switch layer.kind {
        case .path:
            let pts = layer.pathPoints.compactMap { $0.count == 2 ? ctx.px(CGPoint(x: $0[0], y: $0[1])) : nil }
            guard !pts.isEmpty else { return nil }
            bounds = pts.reduce(CGRect(origin: pts[0], size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
            bounds = bounds.insetBy(dx: -(strokeW + 4) - bounds.width * 0.15, dy: -(strokeW + 4) - bounds.height * 0.15)
        default:
            bounds = ctx.pxRect(layer.frame).insetBy(dx: -(strokeW + short * 0.02), dy: -(strokeW + short * 0.02))
        }
        bounds = bounds.intersection(ctx.extent).integral
        guard bounds.width >= 1, bounds.height >= 1, bounds.width * bounds.height < 400_000_000 else { return nil }

        let w = Int(bounds.width), h = Int(bounds.height)
        guard let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: ImagePipeline.sRGB,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        cg.translateBy(x: -bounds.minX, y: -bounds.minY)
        cg.setAllowsAntialiasing(true)
        cg.setShouldAntialias(true)

        switch layer.kind {
        case .text: drawText(layer, in: cg, ctx)
        case .shape: drawShape(layer, in: cg, ctx)
        case .path: drawPath(layer, in: cg, ctx)
        case .adjustment: break
        }
        guard let image = cg.makeImage() else { return nil }
        return (image, bounds)
    }

    private static func fillAndStroke(_ path: CGPath, _ layer: Layer, in cg: CGContext, _ ctx: Context, canFill: Bool = true) {
        if canFill && layer.fillEnabled {
            cg.addPath(path)
            cg.setFillColor(layer.fillColor.cgColor)
            cg.fillPath()
        }
        if layer.strokeEnabled || !canFill {
            cg.addPath(path)
            cg.setStrokeColor((layer.strokeEnabled ? layer.strokeColor : layer.fillColor).cgColor)
            cg.setLineWidth(max(0.5, layer.strokeWidth / 100 * ctx.frameShort))
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            cg.strokePath()
        }
    }

    private static func drawShape(_ layer: Layer, in cg: CGContext, _ ctx: Context) {
        let r = ctx.pxRect(layer.frame)
        let path = CGMutablePath()
        switch layer.shapeKind {
        case .rectangle:
            let radius = min(layer.cornerRadius / 100 * ctx.frameShort, min(r.width, r.height) / 2)
            path.addRoundedRect(in: r, cornerWidth: radius, cornerHeight: radius)
        case .ellipse:
            path.addEllipse(in: r)
        case .line:
            path.move(to: CGPoint(x: r.minX, y: r.midY))
            path.addLine(to: CGPoint(x: r.maxX, y: r.midY))
            fillAndStroke(path, layer, in: cg, ctx, canFill: false)
            return
        case .triangle:
            path.move(to: CGPoint(x: r.midX, y: r.maxY))
            path.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            path.addLine(to: CGPoint(x: r.minX, y: r.minY))
            path.closeSubpath()
        case .star:
            let c = CGPoint(x: r.midX, y: r.midY)
            for i in 0..<10 {
                let a = CGFloat(i) * .pi / 5 + .pi / 2
                let rad: CGFloat = i % 2 == 0 ? 1 : 0.42
                let p = CGPoint(x: c.x + cos(a) * r.width / 2 * rad, y: c.y + sin(a) * r.height / 2 * rad)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.closeSubpath()
        }
        fillAndStroke(path, layer, in: cg, ctx)
    }

    /// Builds a pen-tool path; "smooth" turns the points into flowing Catmull-Rom curves.
    static func penPath(points: [CGPoint], closed: Bool, smooth: Bool) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 1 { return path }
        if !smooth || points.count == 2 {
            for p in points.dropFirst() { path.addLine(to: p) }
            if closed { path.closeSubpath() }
            return path
        }
        let n = points.count
        let segments = closed ? n : n - 1
        func pt(_ i: Int) -> CGPoint {
            if closed { return points[(i % n + n) % n] }
            return points[max(0, min(n - 1, i))]
        }
        for i in 0..<segments {
            let p0 = pt(i - 1), p1 = pt(i), p2 = pt(i + 1), p3 = pt(i + 2)
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        if closed { path.closeSubpath() }
        return path
    }

    private static func drawPath(_ layer: Layer, in cg: CGContext, _ ctx: Context) {
        let pts = layer.pathPoints.compactMap { $0.count == 2 ? ctx.px(CGPoint(x: $0[0], y: $0[1])) : nil }
        guard pts.count >= 2 else {
            if let p = pts.first {   // single point: draw a dot so the user sees where the path starts
                let r = max(2, layer.strokeWidth / 100 * ctx.frameShort)
                cg.setFillColor((layer.strokeEnabled ? layer.strokeColor : layer.fillColor).cgColor)
                cg.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            }
            return
        }
        let path = penPath(points: pts, closed: layer.pathClosed, smooth: layer.pathSmooth)
        fillAndStroke(path, layer, in: cg, ctx, canFill: layer.pathClosed)
    }

    // MARK: Text

    static func font(family: String, weight: Double, italic: Bool, size: CGFloat) -> NSFont {
        let traits: NSFontTraitMask = italic ? [.italicFontMask] : []
        if let f = NSFontManager.shared.font(withFamily: family, traits: traits, weight: Int(weight), size: size) {
            return f
        }
        if let f = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
            return f
        }
        return NSFont.systemFont(ofSize: size)
    }

    static func attributedText(_ layer: Layer, size: CGFloat) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.alignment = layer.alignment == .left ? .left : layer.alignment == .right ? .right : .center
        para.lineSpacing = layer.lineSpacing / 100 * size
        para.lineBreakMode = .byWordWrapping
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font(family: layer.fontFamily, weight: layer.fontWeight, italic: layer.italic, size: size),
            .foregroundColor: NSColor(cgColor: layer.textColor.cgColor) ?? .white,
            .paragraphStyle: para,
            .kern: layer.letterSpacing / 100 * size,
        ]
        if layer.textShadow {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = size * 0.12
            shadow.shadowOffset = NSSize(width: 0, height: -size * 0.04)
            attrs[.shadow] = shadow
        }
        let text = layer.uppercase ? layer.text.uppercased() : layer.text
        return NSAttributedString(string: text, attributes: attrs)
    }

    /// The font size that will actually be used: the requested size, shrunk to fit the box when auto-fit is on.
    static func fittedFontSize(_ layer: Layer, box: CGSize, frameShort: CGFloat) -> CGFloat {
        let requested = max(2, layer.fontSize / 100 * frameShort)
        guard layer.autoFit, box.width > 4, box.height > 4 else { return requested }
        func fits(_ size: CGFloat) -> Bool {
            let r = attributedText(layer, size: size).boundingRect(
                with: CGSize(width: box.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading])
            return r.height <= box.height && r.width <= box.width + 0.5
        }
        if fits(requested) { return requested }
        var lo: CGFloat = 2, hi = requested
        for _ in 0..<14 {
            let mid = (lo + hi) / 2
            if fits(mid) { lo = mid } else { hi = mid }
        }
        return lo
    }

    private static func drawText(_ layer: Layer, in cg: CGContext, _ ctx: Context) {
        let box = ctx.pxRect(layer.frame)
        let size = fittedFontSize(layer, box: box.size, frameShort: ctx.frameShort)
        let str = attributedText(layer, size: size)
        let textRect = str.boundingRect(with: CGSize(width: box.width, height: .greatestFiniteMagnitude),
                                        options: [.usesLineFragmentOrigin, .usesFontLeading])
        // Vertically centered in the box.
        let drawRect = CGRect(x: box.minX, y: box.midY - textRect.height / 2, width: box.width, height: textRect.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
        str.draw(with: drawRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
    }
}
