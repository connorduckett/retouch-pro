import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Finds people, subjects, sky and background in a photo and turns them into grayscale masks.
///
/// People and subjects use Apple's on-device Vision models (nothing leaves the Mac). Sky uses a
/// color/texture flood-fill from the top of the frame. All work happens on one analysis-sized copy
/// of the photo; results are cached so switching selections is instant.
final class AutoMasker {
    let width: Int
    let height: Int
    private let image: CGImage
    /// sRGB RGBA8, row 0 = top.
    private let rgba: [UInt8]

    private var peopleCache: [[UInt8]]?
    private var subjectCache: [[UInt8]]?
    private var skyCache: [Int: [UInt8]] = [:]

    init?(source: CIImage) {
        let small = ImagePipeline.scaled(source, toMaxDimension: 1536)
        guard let cg = ImagePipeline.cgImage(small, colorSpace: ImagePipeline.sRGB) else { return nil }
        image = cg
        width = cg.width
        height = cg.height
        guard let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8,
                                  bytesPerRow: cg.width * 4, space: ImagePipeline.sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        rgba = Array(UnsafeBufferPointer(start: data.bindMemory(to: UInt8.self, capacity: cg.width * cg.height * 4),
                                         count: cg.width * cg.height * 4))
    }

    // MARK: Public

    struct Result {
        var png: Data
        var instanceCount: Int
    }

    /// Builds the mask for a selection type, leaving out the excluded people/subjects.
    func mask(_ mode: MaskMode, excluding excluded: [Int] = [], sensitivity: Double = 50) -> Result? {
        var out = [UInt8](repeating: 0, count: width * height)
        var count = 0
        switch mode {
        case .people:
            let people = peopleMasks()
            count = people.count
            for (i, m) in people.enumerated() where !excluded.contains(i) { maxInto(&out, m) }
        case .subject:
            let subjects = subjectMasks()
            count = subjects.count
            for (i, m) in subjects.enumerated() where !excluded.contains(i) { maxInto(&out, m) }
        case .sky:
            out = skyMask(sensitivity: sensitivity)
        case .background:
            var fg = [UInt8](repeating: 0, count: width * height)
            for m in peopleMasks() { maxInto(&fg, m) }
            for m in subjectMasks() { maxInto(&fg, m) }
            for i in 0..<out.count { out[i] = 255 - fg[i] }
        default:
            return nil
        }
        guard let png = Self.png(out, width, height) else { return nil }
        return Result(png: png, instanceCount: count)
    }

    /// Which person/subject (if any) is at a point. `x`, `y` are 0…1 across the photo, y measured from the top.
    func instance(_ mode: MaskMode, atX x: Double, y: Double) -> Int? {
        let masks: [[UInt8]] = mode == .people ? peopleMasks() : mode == .subject ? subjectMasks() : []
        let px = Int(x * Double(width)), py = Int(y * Double(height))
        guard px >= 0, py >= 0, px < width, py < height else { return nil }
        // Pick the instance with the strongest coverage near the click.
        var best: (Int, Int)?
        for (i, m) in masks.enumerated() {
            var total = 0
            for dy in -3...3 { for dx in -3...3 {
                let xx = min(max(0, px + dx), width - 1), yy = min(max(0, py + dy), height - 1)
                total += Int(m[yy * width + xx])
            } }
            if total > 49 * 90, best == nil || total > best!.1 { best = (i, total) }
        }
        return best?.0
    }

    // MARK: People & subjects (Vision)

    private func peopleMasks() -> [[UInt8]] {
        if let peopleCache { return peopleCache }
        var masks: [[UInt8]] = []
        if #available(macOS 14.0, *) {
            // The instance model also says when there's nobody in the photo, so trust an empty result.
            masks = instanceMasks(VNGeneratePersonInstanceMaskRequest())
        } else {
            // Fallback: one mask with everyone.
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = .accurate
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            if (try? handler.perform([request])) != nil,
               let buffer = request.results?.first?.pixelBuffer,
               let m = gray(from: CIImage(cvPixelBuffer: buffer)), Self.coverage(m) > 0.005 {
                masks = [m]
            }
        }
        peopleCache = masks
        return masks
    }

    private func subjectMasks() -> [[UInt8]] {
        if let subjectCache { return subjectCache }
        var masks: [[UInt8]] = []
        if #available(macOS 14.0, *) {
            masks = instanceMasks(VNGenerateForegroundInstanceMaskRequest())
        }
        if #available(macOS 14.0, *) {} else { masks = peopleMasks() }
        subjectCache = masks
        return masks
    }

    @available(macOS 14.0, *)
    private func instanceMasks(_ request: VNImageBasedRequest) -> [[UInt8]] {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first as? VNInstanceMaskObservation else { return [] }
        var masks: [[UInt8]] = []
        for index in observation.allInstances {
            guard let buffer = try? observation.generateScaledMaskForImage(forInstances: IndexSet(integer: index), from: handler),
                  let m = gray(from: CIImage(cvPixelBuffer: buffer)), Self.coverage(m) > 0.0005 else { continue }
            masks.append(m)
        }
        return masks
    }

    /// Renders a Vision mask into an analysis-sized grayscale buffer (row 0 = top).
    private func gray(from ci: CIImage) -> [UInt8]? {
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / ci.extent.width,
                                                          y: CGFloat(height) / ci.extent.height))
        guard let cg = ImagePipeline.context.createCGImage(
            scaled, from: CGRect(x: 0, y: 0, width: width, height: height),
            format: .L8, colorSpace: CGColorSpaceCreateDeviceGray()) else { return nil }
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Array(UnsafeBufferPointer(start: data.bindMemory(to: UInt8.self, capacity: width * height),
                                         count: width * height))
    }

    // MARK: Sky

    /// `sensitivity` 0…100: higher reaches further into clouds, haze and color changes.
    private func skyMask(sensitivity: Double) -> [UInt8] {
        let key = Int(sensitivity.rounded())
        if let hit = skyCache[key] { return hit }
        let t = Float(max(0, min(100, sensitivity)) / 100)
        let colorTolerance: Float = 0.003 + 0.016 * t * t      // 0.003 … 0.019 (0.007 at 50)
        let textureLimit: Float = 0.024 + 0.02 * t              // 0.024 … 0.044
        let neighborTolerance: Float = 0.0012 + 0.0035 * t      // 0.0012 … 0.0047
        let w = width, h = height, n = w * h

        // Color and luminance.
        var r = [Float](repeating: 0, count: n), g = r, b = r, lum = r
        for i in 0..<n {
            r[i] = Float(rgba[i * 4]) / 255; g[i] = Float(rgba[i * 4 + 1]) / 255; b[i] = Float(rgba[i * 4 + 2]) / 255
            lum[i] = 0.2126 * r[i] + 0.7152 * g[i] + 0.0722 * b[i]
        }
        // Local texture: gradient of a lightly blurred luminance.
        let smooth = Self.boxBlur(lum, w, h, radius: 1)
        var grad = [Float](repeating: 0, count: n)
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let gx = smooth[i + 1] - smooth[i - 1], gy = smooth[i + w] - smooth[i - w]
                grad[i] = (gx * gx + gy * gy).squareRoot()
            }
        }
        let texture = Self.boxBlur(grad, w, h, radius: 2)

        // People and subjects are never sky.
        var foreground = [UInt8](repeating: 0, count: n)
        for m in peopleMasks() { maxInto(&foreground, m) }
        for m in subjectMasks() { maxInto(&foreground, m) }

        func chroma(_ i: Int) -> SIMD3<Float> {
            let c = SIMD3(r[i], g[i], b[i])
            return c / max(0.001, c.sum())
        }
        func candidate(_ i: Int) -> Bool {
            if foreground[i] > 100 { return false }
            if texture[i] > textureLimit || lum[i] < 0.16 { return false }
            let isFoliage = g[i] > r[i] * 1.08 && g[i] > b[i] * 1.05
            return !isFoliage
        }

        // Sweep down the photo row by row. A pixel joins the sky if it touches sky above it (or beside it
        // in the same row), and if its color matches the sky found in the band of rows just above.
        // Comparing against a nearby band lets sunset colors shift gradually, but stops the selection
        // jumping into hazy buildings or water that only *nearly* match.
        var sky = [UInt8](repeating: 0, count: n)
        let band = max(4, h / 10)
        var rowChroma = [SIMD3<Float>](repeating: .zero, count: h)
        var rowLum = [Float](repeating: 0, count: h)
        var rowCount = [Float](repeating: 0, count: h)
        var bandChroma = SIMD3<Float>.zero, bandLum: Float = 0, bandCount: Float = 0
        var mark = [Bool](repeating: false, count: w)

        for y in 0..<h {
            if y > band {
                let old = y - band - 1
                bandChroma -= rowChroma[old]; bandLum -= rowLum[old]; bandCount -= rowCount[old]
            }
            let refChroma = bandCount > 0 ? bandChroma / bandCount : .zero
            let refLum = bandCount > 0 ? bandLum / bandCount : 0

            for x in 0..<w {
                let i = y * w + x
                var ok = candidate(i)
                if ok && bandCount > Float(w / 20) {
                    let d = chroma(i) - refChroma
                    ok = (d * d).sum() < colorTolerance && lum[i] > refLum * 0.45
                }
                mark[x] = ok
                if ok && (y == 0 || sky[i - w] != 0 || (x > 0 && sky[i - w - 1] != 0) || (x < w - 1 && sky[i - w + 1] != 0)) {
                    sky[i] = 255
                }
            }
            // Spread sideways within the row through similar-colored pixels.
            for pass in 0..<2 {
                let xs: StrideThrough<Int> = pass == 0 ? stride(from: 1, through: w - 1, by: 1) : stride(from: w - 2, through: 0, by: -1)
                for x in xs {
                    let i = y * w + x, j = pass == 0 ? i - 1 : i + 1
                    guard sky[i] == 0, mark[x], sky[j] != 0 else { continue }
                    let dr = r[i] - r[j], dg = g[i] - g[j], db = b[i] - b[j]
                    if dr * dr + dg * dg + db * db < neighborTolerance { sky[i] = 255 }
                }
            }
            for x in 0..<w where sky[y * w + x] != 0 {
                let i = y * w + x
                rowChroma[y] += chroma(i); rowLum[y] += lum[i]; rowCount[y] += 1
            }
            bandChroma += rowChroma[y]; bandLum += rowLum[y]; bandCount += rowCount[y]
        }

        var stack: [Int] = []
        stack.reserveCapacity(n / 4)

        // Fill holes completely surrounded by sky (sun, birds, wires) — anything not reachable from
        // the sides or bottom through non-sky pixels.
        var ground = [UInt8](repeating: 0, count: n)
        func seed(_ i: Int) { if sky[i] == 0 && ground[i] == 0 { ground[i] = 1; stack.append(i) } }
        for x in 0..<w { seed((h - 1) * w + x) }
        for y in 0..<h { seed(y * w); seed(y * w + w - 1) }
        while let i = stack.popLast() {
            let x = i % w, y = i / w
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                seed(ny * w + nx)
            }
        }
        for i in 0..<n where sky[i] == 0 && ground[i] == 0 && foreground[i] < 100 { sky[i] = 255 }

        // Clean up speckles, then soften the edge slightly.
        var f = sky.map { Float($0) / 255 }
        f = Self.boxBlur(f, w, h, radius: 2).map { $0 > 0.5 ? 1 : 0 }
        f = Self.boxBlur(f, w, h, radius: 1)
        let result = f.map { UInt8(max(0, min(255, $0 * 255))) }
        skyCache[key] = result
        return result
    }

    // MARK: Helpers

    private func maxInto(_ a: inout [UInt8], _ b: [UInt8]) {
        for i in 0..<min(a.count, b.count) where b[i] > a[i] { a[i] = b[i] }
    }

    private static func coverage(_ m: [UInt8]) -> Double {
        var on = 0
        for v in m where v > 127 { on += 1 }
        return Double(on) / Double(max(1, m.count))
    }

    private static func boxBlur(_ src: [Float], _ w: Int, _ h: Int, radius: Int) -> [Float] {
        guard radius > 0 else { return src }
        var tmp = [Float](repeating: 0, count: src.count), out = tmp
        let size = Float(radius * 2 + 1)
        for y in 0..<h {
            var acc: Float = 0
            for x in -radius...radius { acc += src[y * w + min(max(0, x), w - 1)] }
            for x in 0..<w {
                tmp[y * w + x] = acc / size
                acc += src[y * w + min(w - 1, x + radius + 1)] - src[y * w + max(0, x - radius)]
            }
        }
        for x in 0..<w {
            var acc: Float = 0
            for y in -radius...radius { acc += tmp[min(max(0, y), h - 1) * w + x] }
            for y in 0..<h {
                out[y * w + x] = acc / size
                acc += tmp[min(h - 1, y + radius + 1) * w + x] - tmp[max(0, y - radius) * w + x]
            }
        }
        return out
    }

    static func png(_ gray: [UInt8], _ w: Int, _ h: Int) -> Data? {
        guard let provider = CGDataProvider(data: Data(gray) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                               space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                               provider: provider, decode: nil, shouldInterpolate: true,
                               intent: .defaultIntent) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
