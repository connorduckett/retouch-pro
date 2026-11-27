import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Problems the Culling Assistant can spot in a photo.
enum PhotoIssue: String, Codable, CaseIterable, Identifiable {
    case eyesClosed = "Eyes closed"
    case talking = "Talking / mouth open"
    case blurry = "Out of focus"
    case tooDark = "Too dark"
    case tooBright = "Too bright"
    case similar = "Similar shot"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .eyesClosed: return "eye.slash"
        case .talking: return "mouth"
        case .blurry: return "camera.metering.unknown"
        case .tooDark: return "moon"
        case .tooBright: return "sun.max"
        case .similar: return "square.on.square"
        }
    }
    /// Real problems (as opposed to "there's a better version of this shot").
    var isDefect: Bool { self != .similar }
}

/// Everything the assistant learns about one photo. All on-device (Apple Vision).
struct PhotoAnalysis {
    struct Face {
        var eyeOpenness: Double     // eye height ÷ width (smaller = more closed)
        var mouthOpenness: Double   // inner-lip gap ÷ mouth width
        var smile: Double = 0       // how far the mouth corners lift (÷ mouth width); smiles ≈ 0.08+
        var mouthWidth: Double = 0  // mouth width ÷ face width
        var size: Double            // face width ÷ photo width
        var quality: Double         // Vision face-capture quality 0…1
    }

    var id: UUID
    var date: Date?
    var labels: [String: Float] = [:]
    var faces: [Face] = []
    var sharpness: Double = 0
    var brightness: Double = 0.5
    var shadowsClipped: Double = 0
    var highlightsClipped: Double = 0
    var featurePrint: VNFeaturePrintObservation?
    var issues: Set<PhotoIssue> = []
    var quality: Double = 0
    /// 0…1 position in the shoot's timeline.
    var timeline: Double = 0
    var moment = 0

    var faceCount: Int { faces.count }
    func label(_ names: String...) -> Float { names.map { labels[$0] ?? 0 }.max() ?? 0 }
}

enum CullingEngine {
    /// Tunable thresholds (exposed as "strictness" in the UI).
    /// Thresholds calibrated on sample portraits; "strictness" scales them.
    struct Sensitivity {
        var eyesClosed = 0.11          // eye height ÷ width at or below this = closed
        var eyesClosedNoSmile = 0.16   // narrower eyes count as closed only when not smiling (smiles squint)
        var mouthOpen = 0.22           // open mouth with level/downturned corners = probably talking
        var mouthWideOpen = 0.36       // this open without a clear smile = talking
        var blurFraction = 0.22        // blurry if sharpness < this × the shoot's sharper photos (75th percentile)

        static func strictness(_ level: Int) -> Sensitivity {
            switch level {
            case 0: return Sensitivity(eyesClosed: 0.08, eyesClosedNoSmile: 0.12, mouthOpen: 0.30, mouthWideOpen: 0.45, blurFraction: 0.12)
            case 2: return Sensitivity(eyesClosed: 0.13, eyesClosedNoSmile: 0.19, mouthOpen: 0.17, mouthWideOpen: 0.30, blurFraction: 0.35)
            default: return Sensitivity()
            }
        }
    }

    static func isSmiling(_ f: PhotoAnalysis.Face) -> Bool { f.smile > 0.05 || f.mouthWidth > 0.40 }

    // MARK: Per-photo analysis

    static func analyze(id: UUID, url: URL) -> PhotoAnalysis {
        var a = PhotoAnalysis(id: id)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return a }
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            a.date = captureDate(props)
        }
        if a.date == nil {
            a.date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
        guard let cg = FastPreview.image(at: url, maxPixelSize: 1200) else { return a }

        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        let classify = VNClassifyImageRequest()
        let landmarks = VNDetectFaceLandmarksRequest()
        let quality = VNDetectFaceCaptureQualityRequest()
        let print = VNGenerateImageFeaturePrintRequest()
        try? handler.perform([classify, landmarks, print])

        for obs in classify.results ?? [] where obs.confidence > 0.08 {
            a.labels[obs.identifier] = obs.confidence
        }
        a.featurePrint = print.results?.first as? VNFeaturePrintObservation

        let faces = (landmarks.results ?? []).filter { $0.boundingBox.width > 0.025 }
        if !faces.isEmpty {
            quality.inputFaceObservations = faces
            try? handler.perform([quality])
        }
        let qualities = quality.results ?? []
        for (i, face) in faces.enumerated() {
            var info = PhotoAnalysis.Face(eyeOpenness: 1, mouthOpenness: 0, size: Double(face.boundingBox.width),
                                          quality: Double(i < qualities.count ? qualities[i].faceCaptureQuality ?? 0.5 : 0.5))
            if let lm = face.landmarks {
                let left = ratio(lm.leftEye), right = ratio(lm.rightEye)
                if let l = left, let r = right { info.eyeOpenness = max(l, r) }   // both must be shut to count
                if let inner = lm.innerLips, let outer = lm.outerLips {
                    let gap = extent(inner).height, box = extent(outer), width = box.width
                    if width > 0 {
                        info.mouthOpenness = gap / width
                        info.mouthWidth = width
                        // Corners = leftmost/rightmost outer-lip points; compare with the lips' vertical middle.
                        let pts = outer.normalizedPoints
                        if let l = pts.min(by: { $0.x < $1.x }), let r = pts.max(by: { $0.x < $1.x }) {
                            info.smile = Double(((l.y + r.y) / 2 - box.midY) / width)
                        }
                    }
                }
            }
            a.faces.append(info)
        }

        // Sharpness (focused on faces when there are any) and exposure.
        let (gray, w, h) = grayscale(cg, maxSide: 640)
        // Focus is judged where it matters: on faces, or else on the most detailed part of the frame
        // (a soft sky or plain wall shouldn't make a photo count as blurry).
        // Eyes are where focus is judged; fall back to the whole face.
        let faceRegions: [CGRect] = faces.filter { $0.boundingBox.width > 0.05 }.map { face in
            let bb = face.boundingBox
            var eyes = CGRect.null
            for region in [face.landmarks?.leftEye, face.landmarks?.rightEye].compactMap({ $0 }) {
                let e = extent(region)
                eyes = eyes.union(CGRect(x: bb.minX + e.minX * bb.width, y: bb.minY + e.minY * bb.height,
                                         width: e.width * bb.width, height: e.height * bb.height))
            }
            if eyes.isNull || eyes.width <= 0 { return bb }
            return eyes.insetBy(dx: -eyes.width * 0.25, dy: -max(eyes.height * 1.5, eyes.width * 0.25))
        }
        if !faceRegions.isEmpty {
            a.sharpness = faceRegions.map { laplacianVariance(gray, w, h, region: $0) }.max() ?? 0
        } else {
            var tiles: [Double] = []
            for ty in 0..<5 { for tx in 0..<5 {
                tiles.append(laplacianVariance(gray, w, h, region: CGRect(x: Double(tx) / 5, y: Double(ty) / 5, width: 0.2, height: 0.2)))
            } }
            tiles.sort()
            a.sharpness = tiles[tiles.count - 3]   // third-sharpest tile
        }
        var sum = 0.0, dark = 0, bright = 0
        for v in gray { sum += Double(v); if v < 0.03 { dark += 1 }; if v > 0.97 { bright += 1 } }
        a.brightness = sum / Double(max(1, gray.count))
        a.shadowsClipped = Double(dark) / Double(max(1, gray.count))
        a.highlightsClipped = Double(bright) / Double(max(1, gray.count))
        return a
    }

    private static func captureDate(_ props: [CFString: Any]) -> Date? {
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        guard let s = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String) ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        var date = f.date(from: s)
        if let sub = exif?[kCGImagePropertyExifSubsecTimeOriginal] as? String, let ms = Double("0." + sub) {
            date = date?.addingTimeInterval(ms)
        }
        return date
    }

    private static func extent(_ region: VNFaceLandmarkRegion2D) -> CGRect {
        let pts = region.normalizedPoints
        guard let first = pts.first else { return .zero }
        var r = CGRect(origin: first, size: .zero)
        for p in pts { r = r.union(CGRect(origin: p, size: .zero)) }
        return r
    }

    private static func ratio(_ region: VNFaceLandmarkRegion2D?) -> Double? {
        guard let region, region.pointCount >= 4 else { return nil }
        let r = extent(region)
        return r.width > 0 ? Double(r.height / r.width) : nil
    }

    private static func grayscale(_ cg: CGImage, maxSide: Int) -> ([Float], Int, Int) {
        let scale = min(1, Double(maxSide) / Double(max(cg.width, cg.height)))
        let w = max(1, Int(Double(cg.width) * scale)), h = max(1, Int(Double(cg.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = ctx.data else { return ([], 0, 0) }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = data.bindMemory(to: UInt8.self, capacity: w * h)
        return ((0..<(w * h)).map { Float(px[$0]) / 255 }, w, h)
    }

    /// Variance of the Laplacian inside a normalized (Vision, bottom-left origin) region.
    private static func laplacianVariance(_ g: [Float], _ w: Int, _ h: Int, region: CGRect) -> Double {
        guard w > 4, h > 4 else { return 0 }
        let x0 = max(1, Int(region.minX * CGFloat(w))), x1 = min(w - 2, Int(region.maxX * CGFloat(w)))
        let y0 = max(1, Int((1 - region.maxY) * CGFloat(h))), y1 = min(h - 2, Int((1 - region.minY) * CGFloat(h)))
        guard x1 > x0 + 2, y1 > y0 + 2 else { return 0 }
        var sum = 0.0, sum2 = 0.0, n = 0.0, isum = 0.0, isum2 = 0.0
        for y in y0...y1 {
            for x in x0...x1 {
                let i = y * w + x
                let l = Double(4 * g[i] - g[i - 1] - g[i + 1] - g[i - w] - g[i + w])
                sum += l; sum2 += l * l; n += 1
                isum += Double(g[i]); isum2 += Double(g[i] * g[i])
            }
        }
        let mean = sum / n
        let lapVar = sum2 / n - mean * mean
        // Divide by the area's contrast so dim or low-contrast scenes aren't mistaken for blur.
        let intensityVar = max(0.0004, isum2 / n - (isum / n) * (isum / n))
        return lapVar / intensityVar * 10
    }

    // MARK: Whole-shoot pass

    /// Adds timeline, moments, issues, similar-shot series and a quality score to every photo.
    static func finish(_ photos: inout [PhotoAnalysis], sensitivity s: Sensitivity) {
        guard !photos.isEmpty else { return }
        // Timeline order.
        photos.sort { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
        let first = photos.first?.date, last = photos.last?.date
        let span = max(1, (last ?? Date()).timeIntervalSince(first ?? Date()))
        for i in photos.indices {
            if let d = photos[i].date, first != nil, last != nil, span > 60 {
                photos[i].timeline = d.timeIntervalSince(first!) / span
            } else {
                photos[i].timeline = Double(i) / Double(max(1, photos.count - 1))
            }
        }
        // Moments: a gap of 8+ minutes, or a big visual change between neighbors, starts a new one.
        var moment = 0
        for i in photos.indices {
            if i > 0 {
                let gap = (photos[i].date?.timeIntervalSince(photos[i - 1].date ?? .distantPast)) ?? 0
                let change = distance(photos[i], photos[i - 1]) ?? 0
                if gap > 8 * 60 || (gap > 60 && change > 0.9) { moment += 1 }
            }
            photos[i].moment = moment
        }

        // Issues. Blur is judged against this shoot's own typical sharpness (styles and lenses vary).
        let sharpnessValues = photos.map(\.sharpness).sorted()
        let median = sharpnessValues[sharpnessValues.count / 2]
        let reference = sharpnessValues[min(sharpnessValues.count - 1, sharpnessValues.count * 3 / 4)]
        for i in photos.indices {
            var issues = Set<PhotoIssue>()
            let p = photos[i]
            // Landmarks on tiny or turned faces aren't reliable (they show up as impossible ratios).
            let mainFaces = p.faces.filter { $0.size > 0.06 && $0.eyeOpenness < 1.2 && $0.mouthOpenness < 1 }
            if mainFaces.contains(where: { f in
                f.eyeOpenness <= s.eyesClosed || (f.eyeOpenness <= s.eyesClosedNoSmile && !isSmiling(f))
            }) { issues.insert(.eyesClosed) }
            if mainFaces.contains(where: { f in
                (f.mouthOpenness > s.mouthOpen && f.smile <= 0) || (f.mouthOpenness > s.mouthWideOpen && !isSmiling(f))
            }) { issues.insert(.talking) }
            if reference > 0, p.sharpness < reference * s.blurFraction { issues.insert(.blurry) }
            if p.brightness < 0.13 && p.shadowsClipped > 0.25 { issues.insert(.tooDark) }
            if p.brightness > 0.85 || p.highlightsClipped > 0.3 { issues.insert(.tooBright) }
            photos[i].issues = issues

            // Quality: sharp, well exposed, open eyes, good faces.
            var q = min(2, p.sharpness / max(0.001, median))
            q += p.faces.isEmpty ? 0.5 : p.faces.map(\.quality).reduce(0, +) / Double(p.faces.count)
            q -= Double(issues.count) * 0.6
            q -= abs(p.brightness - 0.48) * 0.8
            photos[i].quality = q
        }

        // Similar shots: consecutive frames that look alike (bursts). Keep the best, mark the rest.
        var start = 0
        func closeSeries(_ end: Int) {
            guard end - start >= 1 else { return }
            let series = start...end
            let best = series.max { photos[$0].quality < photos[$1].quality }!
            for k in series where k != best { photos[k].issues.insert(.similar) }
        }
        for i in 1..<max(1, photos.count) {
            let gap = (photos[i].date?.timeIntervalSince(photos[i - 1].date ?? .distantPast)) ?? 0
            let d = distance(photos[i], photos[i - 1]) ?? 9
            if !(abs(gap) < 6 && d < 0.45) {
                closeSeries(i - 1)
                start = i
            }
        }
        closeSeries(photos.count - 1)
    }

    static func distance(_ a: PhotoAnalysis, _ b: PhotoAnalysis) -> Double? {
        guard let fa = a.featurePrint, let fb = b.featurePrint else { return nil }
        var d: Float = 0
        guard (try? fa.computeDistance(&d, to: fb)) != nil else { return nil }
        return Double(d)
    }
}
