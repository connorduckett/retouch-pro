import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers

/// The non-destructive render pipeline:
/// original → spot heals → rotate/flip/straighten/crop → light & color → detail → look → effects.
enum ImagePipeline {
    static let context: CIContext = {
        CIContext(options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            .cacheIntermediates: false,
        ])
    }()

    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!
    static let linearSRGB = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    // MARK: Loading

    static func load(url: URL) -> CIImage? {
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        var image: CIImage?
        if let type, type.conforms(to: .rawImage), let raw = CIRAWFilter(imageURL: url) {
            image = raw.outputImage
        }
        if image == nil {
            image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
        }
        guard let image, !image.extent.isInfinite, image.extent.width > 0 else { return nil }
        return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }

    static func isRaw(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .rawImage) ?? false
    }

    static func scaled(_ image: CIImage, toMaxDimension maxDim: CGFloat) -> CIImage {
        let longest = max(image.extent.width, image.extent.height)
        guard longest > maxDim else { return image }
        return scaled(image, by: maxDim / longest)
    }

    static func scaled(_ image: CIImage, by scale: CGFloat) -> CIImage {
        guard scale < 0.999 else { return image }
        let out = image.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: scale,
            kCIInputAspectRatioKey: 1.0,
        ])
        let w = floor(image.extent.width * scale), h = floor(image.extent.height * scale)
        return out.cropped(to: CGRect(x: 0, y: 0, width: max(1, w), height: max(1, h)))
    }

    // MARK: Geometry

    struct Geometry {
        var transform: CGAffineTransform
        /// Size of the rotated/straightened frame before cropping.
        var frameSize: CGSize
        /// Crop rectangle in that frame, in pixels.
        var crop: CGRect
    }

    static func geometry(sourceSize: CGSize, state: EditState, ignoreCrop: Bool = false) -> Geometry {
        var t = CGAffineTransform.identity
        var w = sourceSize.width, h = sourceSize.height

        if state.flipHorizontal {
            t = t.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0))
        }
        if state.flipVertical {
            t = t.concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h))
        }
        let turns = ((state.quarterTurns % 4) + 4) % 4
        for _ in 0..<turns {
            // 90° counter-clockwise: (x, y) → (h − y, x)
            t = t.concatenating(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0))
            swap(&w, &h)
        }

        let theta = -state.straighten * .pi / 180
        if abs(theta) > 0.0001 {
            let c = abs(cos(theta)), s = abs(sin(theta))
            let scale = max((w * c + h * s) / w, (w * s + h * c) / h)
            t = t.concatenating(CGAffineTransform(translationX: -w / 2, y: -h / 2))
                .concatenating(CGAffineTransform(rotationAngle: theta))
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: w / 2, y: h / 2))
        }

        let frame = CGRect(x: 0, y: 0, width: w, height: h)
        var crop = frame
        if !ignoreCrop {
            let n = state.crop.standardized
            crop = CGRect(x: n.minX * w, y: n.minY * h, width: n.width * w, height: n.height * h)
                .intersection(frame)
            crop = CGRect(x: crop.minX.rounded(), y: crop.minY.rounded(),
                          width: max(1, crop.width.rounded()), height: max(1, crop.height.rounded()))
        }
        return Geometry(transform: t, frameSize: frame.size, crop: crop)
    }

    // MARK: Render

    /// Builds the edited image. `source` may be a proxy or the full-resolution photo;
    /// every parameter is resolution-independent.
    static func render(source: CIImage, state: EditState, ignoreCrop: Bool = false,
                       maskOverlayLayer: UUID? = nil,
                       maskOverlayColor: CIColor = CIColor(red: 0.95, green: 0.2, blue: 0.25)) -> CIImage {
        let sourceMax = max(source.extent.width, source.extent.height)
        var img = applyHeals(source, heals: state.heals, scale: sourceMax)

        let g = geometry(sourceSize: source.extent.size, state: state, ignoreCrop: ignoreCrop)
        img = img.clampedToExtent()
            .transformed(by: g.transform)
            .cropped(to: g.crop)
            .transformed(by: CGAffineTransform(translationX: -g.crop.minX, y: -g.crop.minY))
        let extent = CGRect(origin: .zero, size: g.crop.size)

        img = applyTone(img, state.adjustments, extent: extent)

        if let look = Look.find(state.lookID), state.lookAmount > 0 {
            var looked = img
            if let a = look.adjustments {
                looked = applyTone(looked, a, extent: extent)
                looked = applyEffects(looked, a, extent: extent)
            }
            if let f = look.filterName {
                looked = looked.applyingFilter(f)
            }
            if state.lookAmount < 100 {
                looked = looked.applyingFilter("CIDissolveTransition", parameters: [
                    kCIInputTargetImageKey: looked,
                    kCIInputImageKey: img,
                    kCIInputTimeKey: state.lookAmount / 100,
                ])
            }
            img = looked
        }

        img = applyEffects(img, state.adjustments, extent: extent)

        // Layers, bottom to top.
        let ctx = LayerRenderer.Context(sourceSize: source.extent.size, geometry: g, extent: extent)
        for layer in state.layers where layer.visible && layer.opacity > 0 {
            img = LayerRenderer.apply(layer, to: img, ctx)
        }
        if let id = maskOverlayLayer, let layer = state.layers.first(where: { $0.id == id }),
           let mask = LayerRenderer.mask(for: layer, ctx) {
            img = LayerRenderer.maskOverlay(mask, over: img, extent: extent, color: maskOverlayColor)
        }
        return img.cropped(to: extent)
    }

    // MARK: Heal

    static func applyHeals(_ image: CIImage, heals: [HealSpot], scale: CGFloat) -> CIImage {
        guard !heals.isEmpty else { return image }
        let extent = image.extent
        var img = image
        for spot in heals where spot.box.count == 4 && spot.gridWidth > 0 && spot.gridHeight > 0 {
            let d = CGPoint(x: spot.dx * scale, y: spot.dy * scale)
            let r = spot.radius * scale
            let box = CGRect(x: spot.box[0] * scale, y: spot.box[1] * scale,
                             width: spot.box[2] * scale, height: spot.box[3] * scale)
            let region = box.intersection(extent)
            guard !region.isEmpty else { continue }

            // 1) Texture from the clean source area.
            var patch = img.clampedToExtent()
                .transformed(by: CGAffineTransform(translationX: -d.x, y: -d.y))

            // 2) Smooth color-correction field so the patch matches its new surroundings.
            if let field = correctionField(spot, box: box) {
                patch = field.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: patch])
            }

            // 3) Soft-edged mask following the click or stroke.
            let mask = strokeMask(points: spot.points, radius: r, scale: scale, box: box)
            let healed = patch.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: img,
                kCIInputMaskImageKey: mask,
            ]).cropped(to: region)
            img = healed.composited(over: img).cropped(to: extent)
        }
        return img
    }

    private static func correctionField(_ spot: HealSpot, box: CGRect) -> CIImage? {
        let gw = spot.gridWidth, gh = spot.gridHeight
        guard spot.grid.count == gw * gh * 3 else { return nil }
        var rgba = [Float](repeating: 0, count: gw * gh * 4)
        for i in 0..<(gw * gh) {
            rgba[i * 4] = spot.grid[i * 3]
            rgba[i * 4 + 1] = spot.grid[i * 3 + 1]
            rgba[i * 4 + 2] = spot.grid[i * 3 + 2]
            rgba[i * 4 + 3] = 0   // leave alpha untouched when added
        }
        let data = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        let small = CIImage(bitmapData: data, bytesPerRow: gw * 16, size: CGSize(width: gw, height: gh),
                            format: .RGBAf, colorSpace: nil)
        return small.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: box.width / CGFloat(gw), y: box.height / CGFloat(gh)))
            .transformed(by: CGAffineTransform(translationX: box.minX, y: box.minY))
            .cropped(to: box)
    }

    /// Grayscale mask of a stroke (or dot) with feathered edges, positioned in image pixels.
    static func strokeMask(points: [[Double]], radius r: CGFloat, scale: CGFloat, box: CGRect,
                           coreFraction: CGFloat = 1.0, softness: CGFloat = 0.17) -> CIImage {
        let k = min(1, 320 / max(box.width, box.height, 1))
        let w = max(2, Int(ceil(box.width * k))), h = max(2, Int(ceil(box.height * k)))
        let gray = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return CIImage.empty() }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let pts = points.compactMap { p -> CGPoint? in
            guard p.count == 2 else { return nil }
            return CGPoint(x: (p[0] * scale - box.minX) * k, y: (p[1] * scale - box.minY) * k)
        }
        let core = r * coreFraction * k
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.setStrokeColor(gray: 1, alpha: 1)
        if pts.count == 1 {
            ctx.fillEllipse(in: CGRect(x: pts[0].x - core, y: pts[0].y - core, width: core * 2, height: core * 2))
        } else if pts.count > 1 {
            ctx.setLineWidth(core * 2)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addLines(between: pts)
            ctx.strokePath()
        }
        guard let cg = ctx.makeImage() else { return CIImage.empty() }
        return CIImage(cgImage: cg)
            .transformed(by: CGAffineTransform(scaleX: 1 / k, y: 1 / k))
            .transformed(by: CGAffineTransform(translationX: box.minX, y: box.minY))
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(0.5, r * softness)])
            .cropped(to: box)
    }

    // MARK: Light, color & detail

    static func applyTone(_ input: CIImage, _ a: Adjustments, extent: CGRect) -> CIImage {
        var img = input
        let sf = max(extent.width, extent.height) / 2000   // spatial scale factor

        if a.exposure != 0 {
            img = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: a.exposure / 100 * 2])
        }

        if a.temperature != 0 || a.tint != 0 {
            img = img.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500 + a.temperature * 30, y: a.tint),
                "inputTargetNeutral": CIVector(x: 6500, y: 0),
            ])
        }

        if a.shadows != 0 || a.highlights < 0 {
            img = img.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputShadowAmount": a.shadows / 100,
                "inputHighlightAmount": 1 + min(0, a.highlights) / 100,
                kCIInputRadiusKey: 0,
            ])
        }

        if a.shadowRemoval > 0 || a.sunSpotRemoval > 0 {
            // Local (large-radius) shadow lift / highlight compression evens out harsh light.
            let sr = a.shadowRemoval / 100, ss = a.sunSpotRemoval / 100
            img = img.clampedToExtent().applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputShadowAmount": sr * 0.95,
                "inputHighlightAmount": 1 - ss * 0.8,
                kCIInputRadiusKey: 24 * sf,
            ]).cropped(to: extent)
            if sr > 0 {
                // Shadows go cool and flat; give them back a little warmth and lift.
                img = img.applyingFilter("CIToneCurve", parameters: [
                    "inputPoint0": CIVector(x: 0, y: 0.02 * sr),
                    "inputPoint1": CIVector(x: 0.15, y: 0.15 + 0.07 * sr),
                    "inputPoint2": CIVector(x: 0.4, y: 0.4 + 0.03 * sr),
                    "inputPoint3": CIVector(x: 0.7, y: 0.7),
                    "inputPoint4": CIVector(x: 1, y: 1),
                ])
            }
            if ss > 0 {
                img = img.applyingFilter("CIToneCurve", parameters: [
                    "inputPoint0": CIVector(x: 0, y: 0),
                    "inputPoint1": CIVector(x: 0.3, y: 0.3),
                    "inputPoint2": CIVector(x: 0.6, y: 0.6 - 0.02 * ss),
                    "inputPoint3": CIVector(x: 0.85, y: 0.85 - 0.07 * ss),
                    "inputPoint4": CIVector(x: 1, y: 1 - 0.06 * ss),
                ])
            }
        }
        if a.skinSpotRemoval > 0 {
            // Small dark marks are darker than their blurred surroundings; "lighten" them away
            // while keeping larger features, then blend in by strength.
            let amt = a.skinSpotRemoval / 100
            let blurred = img.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(1, 7 * sf)])
                .cropped(to: extent)
            let lightened = blurred.applyingFilter("CILightenBlendMode", parameters: [kCIInputBackgroundImageKey: img])
            let smoothed = lightened.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(0.5, 1.2 * sf)])
                .cropped(to: extent)
            img = smoothed.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputImageKey: img,
                kCIInputTargetImageKey: smoothed,
                kCIInputTimeKey: amt * 0.85,
            ]).cropped(to: extent)
        }

        let c = a.contrast / 100, w = a.whites / 100, b = a.blacks / 100
        let hl = max(0, a.highlights) / 100, fade = a.fade / 100
        if c != 0 || w != 0 || b != 0 || hl != 0 || fade != 0 {
            let y0 = max(0, 0.12 * b) + 0.14 * fade
            let y1 = 0.25 + 0.07 * b - 0.05 * c + 0.06 * fade
            let y2 = 0.5 + 0.02 * fade
            let y3 = 0.75 + 0.07 * w + 0.05 * c + 0.06 * hl
            let y4 = 1 + 0.12 * min(0, w) - 0.04 * fade
            img = img.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: y0),
                "inputPoint1": CIVector(x: 0.25, y: y1),
                "inputPoint2": CIVector(x: 0.5, y: y2),
                "inputPoint3": CIVector(x: 0.75, y: y3),
                "inputPoint4": CIVector(x: 1, y: y4),
            ])
        }

        if a.saturation != 0 {
            img = img.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1 + a.saturation / 100,
                kCIInputBrightnessKey: 0,
                kCIInputContrastKey: 1,
            ])
        }
        if a.vibrance != 0 {
            img = img.applyingFilter("CIVibrance", parameters: ["inputAmount": a.vibrance / 100])
        }

        if a.noiseReduction > 0 {
            img = img.clampedToExtent().applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": a.noiseReduction / 100 * 0.06,
                "inputSharpness": 0.4,
            ]).cropped(to: extent)
        }

        if a.clarity > 0 {
            img = img.clampedToExtent().applyingFilter("CIUnsharpMask", parameters: [
                kCIInputRadiusKey: 25 * sf,
                kCIInputIntensityKey: a.clarity / 100 * 0.6,
            ]).cropped(to: extent)
        } else if a.clarity < 0 {
            let soft = img.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 5 * sf])
                .cropped(to: extent)
            img = soft.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputImageKey: img,
                kCIInputTargetImageKey: soft,
                kCIInputTimeKey: -a.clarity / 100 * 0.7,
            ]).cropped(to: extent)
        }

        if a.sharpness > 0 {
            img = img.clampedToExtent().applyingFilter("CIUnsharpMask", parameters: [
                kCIInputRadiusKey: max(0.8, 1.4 * sf),
                kCIInputIntensityKey: a.sharpness / 100 * 1.2,
            ]).cropped(to: extent)
        }
        return img
    }

    static func applyEffects(_ input: CIImage, _ a: Adjustments, extent: CGRect) -> CIImage {
        var img = input
        if a.vignette != 0 {
            img = img.applyingFilter("CIVignetteEffect", parameters: [
                kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
                kCIInputRadiusKey: hypot(extent.width, extent.height) / 2 * 0.9,
                kCIInputIntensityKey: -a.vignette / 100,
                "inputFalloff": 0.5,
            ]).cropped(to: extent)
        }
        if a.grain > 0 {
            let sf = max(1, max(extent.width, extent.height) / 2500)
            let amount = a.grain / 100 * 0.22
            let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!
                .transformed(by: CGAffineTransform(scaleX: sf, y: sf))
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: amount, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: amount, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: amount, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(x: -amount / 2, y: -amount / 2, z: -amount / 2, w: 0),
                ])
                .cropped(to: extent)
            img = noise.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: img])
                .cropped(to: extent)
        }
        return img
    }

    // MARK: Output helpers

    static func cgImage(_ image: CIImage, colorSpace: CGColorSpace = displayP3, format: CIFormat = .RGBA8) -> CGImage? {
        context.createCGImage(image, from: image.extent.integral, format: format, colorSpace: colorSpace)
    }

    /// 256-bin luminance histogram, normalized to 0…1.
    static func histogram(of image: CGImage, normalized: Bool = true) -> [Double] {
        let maxSide = 200.0
        let scale = min(1, maxSide / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return [] }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var bins = [Double](repeating: 0, count: 256)
        for i in 0..<(w * h) {
            let r = Double(px[i * 4]), g = Double(px[i * 4 + 1]), b = Double(px[i * 4 + 2])
            let l = Int((0.2126 * r + 0.7152 * g + 0.0722 * b).rounded())
            bins[min(255, max(0, l))] += 1
        }
        if !normalized { return bins }
        // Normalize against the tallest interior bin so clipped ends don't flatten the graph.
        let peak = max(1, bins[2..<254].max() ?? 1)
        return bins.map { min(1, $0 / peak) }
    }

    static func watermark(text: String, fontSize: CGFloat, opacity: Double) -> CIImage? {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35 * opacity)
        shadow.shadowBlurRadius = fontSize * 0.08
        shadow.shadowOffset = NSSize(width: 0, height: -fontSize * 0.03)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(opacity),
            .shadow: shadow,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        let pad = fontSize * 0.3
        let w = Int(ceil(size.width + pad * 2)), h = Int(ceil(size.height + pad * 2))
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        str.draw(at: NSPoint(x: pad, y: pad))
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg)
    }
}
