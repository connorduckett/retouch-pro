import CoreGraphics
import CoreImage
import Foundation

/// Finds a clean patch of texture to cover a blemish, like a content-aware spot healer.
/// Works on a small linear-light copy of the original photo.
final class HealEngine {
    private let width: Int
    private let height: Int
    private let maxDim: Double
    /// Linear RGB, row 0 = bottom of image (Core Image orientation).
    private var pixels: [SIMD3<Float>]

    init?(image: CIImage) {
        let small = ImagePipeline.scaled(image, toMaxDimension: 1024)
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

    private func sample(_ x: Double, _ y: Double) -> SIMD3<Float>? {
        let xi = Int(x.rounded()), yi = Int(y.rounded())
        guard xi >= 0, yi >= 0, xi < width, yi < height else { return nil }
        return pixels[yi * width + xi]
    }

    /// Offsets of sample points within a disk/annulus, in pixels.
    private func ring(inner: Double, outer: Double) -> [SIMD2<Double>] {
        let step = max(1, outer / 7)
        var pts: [SIMD2<Double>] = []
        var y = -outer
        while y <= outer {
            var x = -outer
            while x <= outer {
                let d = (x * x + y * y).squareRoot()
                if d >= inner && d <= outer { pts.append(SIMD2(x, y)) }
                x += step
            }
            y += step
        }
        return pts
    }

    /// Returns a heal spot for a click at the given normalized position.
    func heal(x nx: Double, y ny: Double, radius nr: Double) -> HealSpot {
        let cx = nx * maxDim, cy = ny * maxDim
        let r = max(1.5, nr * maxDim)

        let annulus = ring(inner: r * 1.05, outer: r * 1.6)
        let disk = ring(inner: 0, outer: r)

        func mean(at c: SIMD2<Double>, _ pts: [SIMD2<Double>]) -> SIMD3<Float>? {
            var sum = SIMD3<Float>.zero, n: Float = 0
            for p in pts {
                if let v = sample(c.x + p.x, c.y + p.y) { sum += v; n += 1 }
            }
            return n > 0 ? sum / n : nil
        }

        let target = SIMD2(cx, cy)
        let targetRing = mean(at: target, annulus) ?? .zero

        var best: (score: Float, offset: SIMD2<Double>)? = nil
        for distance in [2.3, 3.0, 4.0] {
            let count = 16
            for k in 0..<count {
                let a = Double(k) / Double(count) * 2 * .pi
                let off = SIMD2(cos(a), sin(a)) * (r * distance)
                let cand = target + off
                // Candidate must be fully inside the photo.
                guard cand.x - r * 1.6 >= 0, cand.y - r * 1.6 >= 0,
                      cand.x + r * 1.6 < Double(width), cand.y + r * 1.6 < Double(height) else { continue }

                // 1) Its surroundings should look like the blemish's surroundings.
                var ringErr: Float = 0, n: Float = 0
                for p in annulus {
                    guard let a = sample(target.x + p.x, target.y + p.y),
                          let b = sample(cand.x + p.x, cand.y + p.y) else { continue }
                    let d = a - b
                    ringErr += (d * d).sum(); n += 1
                }
                guard n > 0 else { continue }
                ringErr /= n

                // 2) Its interior should be clean and smooth (no other blemish).
                var interiorErr: Float = 0, m: Float = 0
                let candRing = mean(at: cand, annulus) ?? targetRing
                for p in disk {
                    guard let v = sample(cand.x + p.x, cand.y + p.y) else { continue }
                    let d = v - candRing
                    interiorErr += (d * d).sum(); m += 1
                }
                if m > 0 { interiorErr /= m }

                let score = ringErr + interiorErr * 1.5 + Float(distance) * 0.00005
                if best == nil || score < best!.score {
                    best = (score, off)
                }
            }
        }

        let offset = best?.offset ?? SIMD2(r * 2.5, 0)
        let source = target + offset
        let sourceRing = mean(at: source, annulus) ?? targetRing
        let bias = targetRing - sourceRing

        return HealSpot(
            x: nx, y: ny, radius: nr,
            dx: offset.x / maxDim, dy: offset.y / maxDim,
            biasR: Double(bias.x), biasG: Double(bias.y), biasB: Double(bias.z)
        )
    }
}
