import CoreGraphics
import CoreImage
import Foundation

/// Content-aware spot healing.
///
/// For each click or brush stroke it:
/// 1. finds one clean area nearby whose texture best matches the surroundings (one offset per stroke,
///    so a stroke never turns into a patchwork),
/// 2. measures the color difference all around the edge of the healed area and interpolates it smoothly
///    across the inside ("membrane" blending). The patch keeps its own fine texture but takes on the
///    exact light and color of where it lands, so there is no visible edge or tone shift.
final class HealEngine {
    private let width: Int
    private let height: Int
    private let maxDim: Double
    /// Linear RGB, row 0 = bottom of image (Core Image orientation).
    private var pixels: [SIMD3<Float>]

    init?(image: CIImage) {
        let small = ImagePipeline.scaled(image, toMaxDimension: 1600)
        guard let cg = ImagePipeline.cgImage(small, colorSpace: ImagePipeline.sRGB) else { return nil }
        let w = cg.width, h = cg.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: ImagePipeline.sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let raw = data.bindMemory(to: UInt8.self, capacity: w * h * 4)

        var lut = [Float](repeating: 0, count: 256)
        for i in 0..<256 {
            let v = Float(i) / 255
            lut[i] = v <= 0.04045 ? v / 12.92 : powf((v + 0.055) / 1.055, 2.4)
        }
        var px = [SIMD3<Float>](repeating: .zero, count: w * h)
        for row in 0..<h {
            let y = h - 1 - row   // bitmap memory is top-down
            for x in 0..<w {
                let i = (row * w + x) * 4
                px[y * w + x] = SIMD3(lut[Int(raw[i])], lut[Int(raw[i + 1])], lut[Int(raw[i + 2])])
            }
        }
        width = w; height = h
        maxDim = Double(max(w, h))
        pixels = px
    }

    // MARK: Sampling

    /// Bilinear sample in bitmap pixels.
    private func sample(_ x: Double, _ y: Double) -> SIMD3<Float>? {
        guard x >= 0, y >= 0, x <= Double(width - 1), y <= Double(height - 1) else { return nil }
        let x0 = Int(x), y0 = Int(y)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let fx = Float(x - Double(x0)), fy = Float(y - Double(y0))
        let a = pixels[y0 * width + x0], b = pixels[y0 * width + x1]
        let c = pixels[y1 * width + x0], d = pixels[y1 * width + x1]
        return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
    }

    /// Mean of a small neighborhood — robust against noise and grain.
    private func smoothSample(_ x: Double, _ y: Double, _ s: Double) -> SIMD3<Float>? {
        var sum = SIMD3<Float>.zero, n: Float = 0
        for (ox, oy) in [(0.0, 0.0), (s, 0), (-s, 0), (0, s), (0, -s)] {
            if let v = sample(x + ox, y + oy) { sum += v; n += 1 }
        }
        return n > 0 ? sum / n : nil
    }

    private static func distanceToPolyline(_ p: SIMD2<Double>, _ pts: [SIMD2<Double>]) -> Double {
        guard pts.count > 1 else { return pts.first.map { simdLength(p - $0) } ?? .infinity }
        var best = Double.infinity
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            let ab = b - a
            let len2 = simdDot(ab, ab)
            let t = len2 > 0 ? max(0, min(1, simdDot(p - a, ab) / len2)) : 0
            best = min(best, simdLength(p - (a + ab * t)))
        }
        return best
    }

    // MARK: Healing

    /// Heals along a click (one point) or a brush stroke. Coordinates are normalized by the photo's
    /// longest side with a bottom-left origin.
    func heal(points normalized: [CGPoint], radius nr: Double) -> HealSpot? {
        guard !normalized.isEmpty else { return nil }
        let r = max(1.5, nr * maxDim)
        // Resample the stroke so points are evenly spaced (~r/2 apart).
        var pts: [SIMD2<Double>] = []
        for p in normalized.map({ SIMD2(Double($0.x) * maxDim, Double($0.y) * maxDim) }) {
            if let last = pts.last {
                let dist = simdLength(p - last)
                if dist < r * 0.5 { continue }
                let steps = Int(dist / (r * 0.5))
                for s in 1..<max(1, steps) { pts.append(last + (p - last) * (Double(s) / Double(steps))) }
            }
            pts.append(p)
        }

        let offset = bestOffset(for: pts, radius: r)

        // Bounding box of the healed region (in bitmap pixels), padded by the brush radius.
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let pad = r * 1.7
        let box = CGRect(x: xs.min()! - pad, y: ys.min()! - pad,
                         width: xs.max()! - xs.min()! + pad * 2, height: ys.max()! - ys.min()! + pad * 2)

        // Membrane: color difference (destination − source) measured just outside the region.
        var boundary: [(SIMD2<Double>, SIMD3<Float>)] = []
        let ringR = r * 1.45
        let angles = 28
        for p in pts {
            for k in 0..<angles {
                let a = Double(k) / Double(angles) * 2 * .pi
                let q = p + SIMD2(cos(a), sin(a)) * ringR
                guard Self.distanceToPolyline(q, pts) >= r * 1.35 else { continue }
                let s = max(0.6, r * 0.12)
                guard let dst = smoothSample(q.x, q.y, s),
                      let src = smoothSample(q.x + offset.x, q.y + offset.y, s) else { continue }
                boundary.append((q, dst - src))
            }
        }
        if boundary.count > 400 {   // keep it fast on long strokes
            let step = Double(boundary.count) / 400
            boundary = (0..<400).map { boundary[Int(Double($0) * step)] }
        }

        // Interpolate the boundary differences across a small grid (inverse-distance weighting).
        let aspect = box.width / box.height
        let gw = max(4, min(32, Int((aspect >= 1 ? 24 : 24 * aspect).rounded())))
        let gh = max(4, min(32, Int((aspect >= 1 ? 24 / aspect : 24).rounded())))
        var grid = [Float](repeating: 0, count: gw * gh * 3)
        for j in 0..<gh {
            for i in 0..<gw {
                let c = SIMD2(Double(box.minX) + (Double(i) + 0.5) / Double(gw) * Double(box.width),
                              Double(box.minY) + (Double(j) + 0.5) / Double(gh) * Double(box.height))
                var sum = SIMD3<Float>.zero, wsum: Float = 0
                for (q, d) in boundary {
                    let dist2 = Float(simdDot(q - c, q - c)) + Float(r * r) * 0.01
                    let w = 1 / (dist2 * dist2)
                    sum += d * w; wsum += w
                }
                let v = wsum > 0 ? sum / wsum : .zero
                let idx = (j * gw + i) * 3
                grid[idx] = v.x; grid[idx + 1] = v.y; grid[idx + 2] = v.z
            }
        }

        return HealSpot(
            points: pts.map { [$0.x / maxDim, $0.y / maxDim] },
            radius: r / maxDim,
            dx: offset.x / maxDim, dy: offset.y / maxDim,
            box: [box.minX / maxDim, box.minY / maxDim, box.width / maxDim, box.height / maxDim],
            gridWidth: gw, gridHeight: gh, grid: grid
        )
    }

    /// Single-point convenience used by clicks.
    func heal(x: Double, y: Double, radius: Double) -> HealSpot? {
        heal(points: [CGPoint(x: x, y: y)], radius: radius)
    }

    /// Picks the source offset whose texture best matches the stroke's surroundings.
    private func bestOffset(for pts: [SIMD2<Double>], radius r: Double) -> SIMD2<Double> {
        // Evaluate on at most ~10 points along the stroke.
        let stride = max(1, pts.count / 10)
        let probes = Swift.stride(from: 0, to: pts.count, by: stride).map { pts[$0] }

        // Annulus sample offsets (texture just outside the spot) and disk offsets (the patch itself).
        func ring(_ inner: Double, _ outer: Double) -> [SIMD2<Double>] {
            let step = max(0.75, outer / 6)
            var out: [SIMD2<Double>] = []
            var y = -outer
            while y <= outer {
                var x = -outer
                while x <= outer {
                    let d = (x * x + y * y).squareRoot()
                    if d >= inner && d <= outer { out.append(SIMD2(x, y)) }
                    x += step
                }
                y += step
            }
            return out
        }
        let annulus = ring(r * 1.35, r * 2.0)
        let disk = ring(0, r)

        let extent = SIMD2(pts.map(\.x).max()! - pts.map(\.x).min()!, pts.map(\.y).max()! - pts.map(\.y).min()!)
        let strokeLength = simdLength(extent)

        var best: (score: Float, offset: SIMD2<Double>)?
        for distance in [2.9, 3.5, 4.3, 5.4, 7.0] {
            let reach = r * distance + strokeLength * 0.35
            for k in 0..<24 {
                let a = Double(k) / 24 * 2 * .pi
                let off = SIMD2(cos(a), sin(a)) * reach

                // The source must be inside the photo and must not overlap the stroke itself.
                var valid = true
                for p in pts {
                    let q = p + off
                    if q.x - r * 2.0 < 0 || q.y - r * 2.0 < 0 ||
                        q.x + r * 2.0 > Double(width - 1) || q.y + r * 2.0 > Double(height - 1) ||
                        Self.distanceToPolyline(q, pts) < r * 2.8 { valid = false; break }
                }
                guard valid else { continue }

                var score: Float = 0
                for p in probes {
                    let q = p + off
                    // Texture match around the edge, with brightness differences removed
                    // (the membrane fixes brightness; texture can't be fixed).
                    var dstVals: [SIMD3<Float>] = [], srcVals: [SIMD3<Float>] = []
                    for v in annulus {
                        guard let a = sample(p.x + v.x, p.y + v.y), let b = sample(q.x + v.x, q.y + v.y) else { continue }
                        dstVals.append(a); srcVals.append(b)
                    }
                    guard !dstVals.isEmpty else { continue }
                    let n = Float(dstVals.count)
                    let dm = dstVals.reduce(.zero, +) / n, sm = srcVals.reduce(.zero, +) / n
                    var tex: Float = 0
                    for i in 0..<dstVals.count {
                        let d = (dstVals[i] - dm) - (srcVals[i] - sm)
                        tex += (d * d).sum()
                    }
                    tex /= n
                    let meanDiff = dm - sm
                    // The patch interior should be clean: no other blemish inside.
                    var interior: Float = 0, m: Float = 0
                    for v in disk {
                        guard let s = sample(q.x + v.x, q.y + v.y) else { continue }
                        let d = s - sm
                        interior += (d * d).sum(); m += 1
                    }
                    if m > 0 { interior /= m }
                    score += tex * 2 + interior + (meanDiff * meanDiff).sum() * 0.35
                }
                score += Float(distance) * 0.00002
                if best == nil || score < best!.score { best = (score, off) }
            }
        }
        return best?.offset ?? SIMD2(r * 3 + strokeLength, 0)
    }
}

@inline(__always) func simdLength(_ v: SIMD2<Double>) -> Double { (v.x * v.x + v.y * v.y).squareRoot() }
@inline(__always) func simdDot(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { a.x * b.x + a.y * b.y }
