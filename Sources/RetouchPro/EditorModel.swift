import AppKit
import CoreImage
import SwiftUI
import UniformTypeIdentifiers

final class EditorModel: ObservableObject {
    static let shared = EditorModel()

    // Document
    @Published private(set) var fileURL: URL?
    @Published private(set) var fullSize: CGSize = .zero
    @Published private(set) var isRaw = false
    @Published private(set) var isLoading = false
    @Published var loadError: String?

    // Editing
    @Published var state = EditState() {
        didSet { if state != oldValue { scheduleRender() } }
    }
    @Published var tool: Tool = .adjust {
        didSet {
            if tool != oldValue && (tool == .crop || oldValue == .crop) { scheduleRender() }
        }
    }
    @Published var cropAspect: AspectRatio = .free
    @Published var healBrushSize: Double = 40   // on-screen diameter in points

    // Display
    @Published private(set) var preview: NSImage?
    @Published private(set) var originalPreview: NSImage?
    @Published private(set) var histogram: [Double] = []
    @Published private(set) var lookThumbnails: [String: NSImage] = [:]
    @Published var showOriginal = false
    /// 1 = fit to window.
    @Published var zoom: CGFloat = 1 {
        didSet { if zoom != oldValue { scheduleRender() } }
    }
    var viewportSize: CGSize = .zero
    var backingScale: CGFloat = 2

    // History
    @Published private(set) var history: [EditState] = [EditState()]
    @Published private(set) var historyIndex = 0
    @Published private(set) var hasUnexportedChanges = false
    private var clipboard: (Adjustments, String?, Double)?
    @Published private(set) var hasClipboard = false

    // Sources
    private var sourceFull: CIImage?
    private var sourceProxy: CIImage?
    private var healEngine: HealEngine?
    private let proxyMax: CGFloat = 2400

    private let renderQueue = DispatchQueue(label: "retouchpro.render", qos: .userInteractive)
    private let workQueue = DispatchQueue(label: "retouchpro.work", qos: .userInitiated)
    private var isRendering = false
    private var needsRender = false
    private var loadToken = UUID()

    var hasImage: Bool { sourceFull != nil }
    var canUndo: Bool { historyIndex > 0 }
    var canRedo: Bool { historyIndex < history.count - 1 }
    var fileName: String { fileURL?.lastPathComponent ?? "" }

    /// Size of the edited (cropped) photo at full resolution.
    var outputSize: CGSize {
        guard fullSize != .zero else { return .zero }
        return ImagePipeline.geometry(sourceSize: fullSize, state: state).crop.size
    }

    /// Size of the rotated/straightened frame (what the crop tool shows).
    var frameSize: CGSize {
        guard fullSize != .zero else { return .zero }
        return ImagePipeline.geometry(sourceSize: fullSize, state: state, ignoreCrop: true).frameSize
    }

    // MARK: Opening

    static let supportedTypes: [UTType] = [.image, .rawImage, .jpeg, .png, .heic, .tiff]

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.supportedTypes
        panel.allowsMultipleSelection = false
        panel.message = "Choose a photo to edit"
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url {
            open(url: url)
        }
    }

    func open(url: URL) {
        guard confirmDiscardIfNeeded() else { return }
        let token = UUID()
        loadToken = token
        isLoading = true
        loadError = nil
        workQueue.async { [weak self] in
            guard let self else { return }
            guard let full = ImagePipeline.load(url: url) else {
                DispatchQueue.main.async {
                    guard self.loadToken == token else { return }
                    self.isLoading = false
                    self.loadError = "Retouch Pro couldn't open “\(url.lastPathComponent)”. Try a JPEG, PNG, HEIC, TIFF or camera RAW file."
                }
                return
            }
            // Bake a proxy for fast, interactive editing.
            let proxyCI = ImagePipeline.scaled(full, toMaxDimension: self.proxyMax)
            let proxyCG = ImagePipeline.cgImage(proxyCI, colorSpace: ImagePipeline.linearSRGB, format: .RGBAh)
            let proxy = proxyCG.map { CIImage(cgImage: $0) } ?? proxyCI
            let heal = HealEngine(image: proxy)
            let originalCG = ImagePipeline.cgImage(proxy)
            let originalNS = originalCG.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }

            DispatchQueue.main.async {
                guard self.loadToken == token else { return }
                self.sourceFull = full
                self.sourceProxy = proxy
                self.healEngine = heal
                self.fullSize = full.extent.size
                self.isRaw = ImagePipeline.isRaw(url)
                self.fileURL = url
                self.originalPreview = originalNS
                self.history = [EditState()]
                self.historyIndex = 0
                self.hasUnexportedChanges = false
                self.zoom = 1
                self.tool = .adjust
                self.lookThumbnails = [:]
                self.preview = nil
                self.state = EditState()
                self.isLoading = false
                self.scheduleRender()
                self.buildLookThumbnails()
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
            }
        }
    }

    private func confirmDiscardIfNeeded() -> Bool {
        guard hasImage, hasUnexportedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "Discard your edits?"
        alert.informativeText = "You haven’t exported “\(fileName)” since your last change."
        alert.addButton(withTitle: "Discard Edits")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func close() {
        guard confirmDiscardIfNeeded() else { return }
        loadToken = UUID()
        sourceFull = nil; sourceProxy = nil; healEngine = nil
        fileURL = nil; preview = nil; originalPreview = nil
        histogram = []; lookThumbnails = [:]
        history = [EditState()]; historyIndex = 0
        hasUnexportedChanges = false
        state = EditState()
    }

    // MARK: History

    /// Records the current state as an undo step (call when a gesture ends or a button is pressed).
    func commit() {
        guard state != history[historyIndex] else { return }
        history = Array(history.prefix(historyIndex + 1)) + [state]
        historyIndex = history.count - 1
        hasUnexportedChanges = true
    }

    func apply(_ change: (inout EditState) -> Void) {
        var s = state
        change(&s)
        state = s
        commit()
    }

    func undo() {
        guard canUndo else { return }
        historyIndex -= 1
        state = history[historyIndex]
        hasUnexportedChanges = true
    }

    func redo() {
        guard canRedo else { return }
        historyIndex += 1
        state = history[historyIndex]
        hasUnexportedChanges = true
    }

    func resetAll() {
        apply { $0 = EditState() }
    }

    func copyEdits() {
        clipboard = (state.adjustments, state.lookID, state.lookAmount)
        hasClipboard = true
    }

    func pasteEdits() {
        guard let clip = clipboard else { return }
        apply {
            $0.adjustments = clip.0
            $0.lookID = clip.1
            $0.lookAmount = clip.2
        }
    }

    // MARK: Auto enhance

    func autoEnhance() {
        guard let original = originalPreview?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let bins = ImagePipeline.histogram(of: original, normalized: false)
        let total = bins.reduce(0, +)
        guard total > 0 else { return }
        func percentile(_ p: Double) -> Double {
            var acc = 0.0
            for (i, v) in bins.enumerated() {
                acc += v
                if acc / total >= p { return Double(i) / 255 }
            }
            return 1
        }
        let low = percentile(0.01), mid = percentile(0.5), high = percentile(0.99)

        var a = Adjustments()
        if mid > 0.02 {
            let ev = log2(pow(0.46 / mid, 2.2))
            a.exposure = max(-60, min(60, ev / 2 * 100 * 0.6))
        }
        if high < 0.96 { a.whites = min(50, (0.97 - high) * 250) }
        if low > 0.04 { a.blacks = max(-50, -(low - 0.02) * 300) }
        if high > 0.985 { a.highlights = -25 }
        if low < 0.02 { a.shadows = 15 }
        a.contrast = 8
        a.vibrance = 22
        a.clarity = 8

        apply {
            let keep = $0.adjustments
            $0.adjustments = a
            // Keep the user's detail & effects choices.
            $0.adjustments.sharpness = keep.sharpness
            $0.adjustments.noiseReduction = keep.noiseReduction
            $0.adjustments.vignette = keep.vignette
            $0.adjustments.grain = keep.grain
            $0.adjustments.fade = keep.fade
        }
    }

    // MARK: Crop & rotate

    func rotateLeft() { apply { $0.quarterTurns += 1; $0.crop = EditState.fullCrop } ; applyAspect() }
    func rotateRight() { apply { $0.quarterTurns += 3; $0.crop = EditState.fullCrop } ; applyAspect() }
    func flipHorizontal() { apply { $0.flipHorizontal.toggle(); $0.crop = EditState.fullCrop } ; applyAspect() }
    func flipVertical() { apply { $0.flipVertical.toggle(); $0.crop = EditState.fullCrop } ; applyAspect() }

    func resetCrop() {
        cropAspect = .free
        apply {
            $0.crop = EditState.fullCrop
            $0.straighten = 0
            $0.quarterTurns = 0
            $0.flipHorizontal = false
            $0.flipVertical = false
        }
    }

    /// Pixel aspect (w/h) the crop must keep, or nil for free.
    var lockedAspect: Double? {
        switch cropAspect {
        case .free: return nil
        case .original: return fullSize.height > 0 ? Double(frameSize.width / frameSize.height) : nil
        default:
            guard let portrait = cropAspect.portraitValue else { return nil }
            // Match the photo's orientation.
            let landscape = frameSize.width >= frameSize.height
            return landscape ? 1 / portrait : portrait
        }
    }

    var cropIsLandscapeFlipped = false

    func applyAspect() {
        guard var ratio = lockedAspect, frameSize.width > 0 else { return }
        if cropIsLandscapeFlipped { ratio = 1 / ratio }
        let fw = Double(frameSize.width), fh = Double(frameSize.height)
        // Largest rect with this pixel ratio, centered on the current crop.
        let current = state.crop
        var w = fw, h = fw / ratio
        if h > fh { h = fh; w = fh * ratio }
        let nw = w / fw, nh = h / fh
        var x = current.midX - nw / 2, y = current.midY - nh / 2
        x = min(max(0, x), 1 - nw); y = min(max(0, y), 1 - nh)
        apply { $0.crop = CGRect(x: x, y: y, width: nw, height: nh) }
    }

    func swapAspectOrientation() {
        cropIsLandscapeFlipped.toggle()
        applyAspect()
    }

    // MARK: Heal

    /// `point` is normalized (0…1) in the displayed, cropped photo with a top-left origin.
    func heal(atDisplayPoint point: CGPoint, displaySize: CGSize) {
        guard let engine = healEngine, fullSize != .zero, displaySize.width > 0 else { return }
        let g = ImagePipeline.geometry(sourceSize: fullSize, state: state)
        let outPt = CGPoint(x: g.crop.minX + point.x * g.crop.width,
                            y: g.crop.minY + (1 - point.y) * g.crop.height)
        let inv = g.transform.inverted()
        let src = outPt.applying(inv)
        let maxDim = max(fullSize.width, fullSize.height)

        // Brush radius: screen points → output pixels → source pixels.
        let outRadius = (healBrushSize / 2) / displaySize.width * g.crop.width
        let v = CGPoint(x: outRadius, y: 0).applying(CGAffineTransform(a: inv.a, b: inv.b, c: inv.c, d: inv.d, tx: 0, ty: 0))
        let srcRadius = hypot(v.x, v.y)

        guard src.x >= 0, src.y >= 0, src.x <= fullSize.width, src.y <= fullSize.height else { return }
        let spot = engine.heal(x: src.x / maxDim, y: src.y / maxDim, radius: srcRadius / maxDim)
        apply { $0.heals.append(spot) }
    }

    /// Positions of heal spots in normalized display coordinates (top-left origin) for drawing markers.
    func healMarkers(displaySize: CGSize) -> [(CGPoint, CGFloat)] {
        guard fullSize != .zero else { return [] }
        let g = ImagePipeline.geometry(sourceSize: fullSize, state: state)
        let maxDim = max(fullSize.width, fullSize.height)
        return state.heals.compactMap { spot in
            let p = CGPoint(x: spot.x * maxDim, y: spot.y * maxDim).applying(g.transform)
            let nx = (p.x - g.crop.minX) / g.crop.width
            let ny = 1 - (p.y - g.crop.minY) / g.crop.height
            guard (0...1).contains(nx), (0...1).contains(ny) else { return nil }
            let rv = CGPoint(x: spot.radius * maxDim, y: 0)
                .applying(CGAffineTransform(a: g.transform.a, b: g.transform.b, c: g.transform.c, d: g.transform.d, tx: 0, ty: 0))
            let r = hypot(rv.x, rv.y) / g.crop.width * displaySize.width
            return (CGPoint(x: nx, y: ny), r)
        }
    }

    // MARK: Rendering

    func scheduleRender() {
        guard sourceProxy != nil else { return }
        needsRender = true
        guard !isRendering else { return }
        startRender()
    }

    private func startRender() {
        guard let proxy = sourceProxy, let full = sourceFull else { return }
        needsRender = false
        isRendering = true

        let state = self.state
        let ignoreCrop = tool == .crop
        let token = loadToken

        // Pick a source resolution: the proxy is plenty for "fit"; zooming in uses the full photo.
        var source = proxy
        if zoom > 1.01 && viewportSize.width > 0 {
            let g = ImagePipeline.geometry(sourceSize: fullSize, state: state, ignoreCrop: ignoreCrop)
            let fit = min(viewportSize.width / g.crop.width, viewportSize.height / g.crop.height)
            let neededScale = min(1, fit * zoom * backingScale)   // relative to full resolution
            let neededMax = neededScale * max(fullSize.width, fullSize.height)
            if neededMax > proxyMax * 1.05 {
                source = ImagePipeline.scaled(full, by: neededScale)
            }
        }

        renderQueue.async { [weak self] in
            let output = ImagePipeline.render(source: source, state: state, ignoreCrop: ignoreCrop)
            let cg = ImagePipeline.cgImage(output)
            let hist = cg.map { ImagePipeline.histogram(of: $0) } ?? []
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRendering = false
                if self.loadToken == token, let cg {
                    self.preview = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    self.histogram = hist
                }
                if self.needsRender { self.startRender() }
            }
        }
    }

    private func buildLookThumbnails() {
        guard let proxy = sourceProxy else { return }
        let token = loadToken
        workQueue.async { [weak self] in
            let small = ImagePipeline.scaled(proxy, toMaxDimension: 220)
            var result: [String: NSImage] = [:]
            func ns(_ img: CIImage) -> NSImage? {
                guard let cg = ImagePipeline.cgImage(img) else { return nil }
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
            result["none"] = ns(small)
            for look in Look.all {
                var s = EditState()
                s.lookID = look.id
                if let img = ns(ImagePipeline.render(source: small, state: s)) {
                    result[look.id] = img
                }
            }
            DispatchQueue.main.async {
                guard let self, self.loadToken == token else { return }
                self.lookThumbnails = result
            }
        }
    }

    // MARK: Export

    struct ExportOptions {
        enum Format: String, CaseIterable, Identifiable {
            case jpeg = "JPEG", heic = "HEIC", png = "PNG", tiff = "TIFF"
            var id: String { rawValue }
            var type: UTType {
                switch self {
                case .jpeg: return .jpeg
                case .heic: return .heic
                case .png: return .png
                case .tiff: return .tiff
                }
            }
            var ext: String {
                switch self {
                case .jpeg: return "jpg"
                case .heic: return "heic"
                case .png: return "png"
                case .tiff: return "tif"
                }
            }
            var isLossy: Bool { self == .jpeg || self == .heic }
        }
        enum ColorProfile: String, CaseIterable, Identifiable {
            case sRGB = "sRGB", displayP3 = "Display P3"
            var id: String { rawValue }
            var space: CGColorSpace { self == .sRGB ? ImagePipeline.sRGB : ImagePipeline.displayP3 }
        }
        enum WatermarkPosition: String, CaseIterable, Identifiable {
            case bottomRight = "Bottom Right", bottomLeft = "Bottom Left", center = "Center"
            case topRight = "Top Right", topLeft = "Top Left"
            var id: String { rawValue }
        }

        var format: Format = .jpeg
        var quality: Double = 90
        /// Longest edge in pixels, or nil for full size.
        var longEdge: Int? = nil
        var colorProfile: ColorProfile = .sRGB
        var keepMetadata = true
        var watermark = false
        var watermarkText = "© "
        var watermarkPosition: WatermarkPosition = .bottomRight
        var watermarkOpacity: Double = 70
        var watermarkSize: Double = 3   // % of long edge
    }

    @Published var exportOptions = ExportOptions()
    @Published var isExporting = false
    @Published var lastExportURL: URL?

    func suggestedExportName() -> String {
        let base = fileURL?.deletingPathExtension().lastPathComponent ?? "Photo"
        return "\(base)-edited.\(exportOptions.format.ext)"
    }

    func export(to url: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        guard let full = sourceFull else { return }
        let options = exportOptions
        let state = self.state
        let fullSize = self.fullSize
        let sourceURL = fileURL
        isExporting = true

        workQueue.async { [weak self] in
            let result: Result<URL, Error> = Result {
                var source = full
                if let target = options.longEdge {
                    let out = ImagePipeline.geometry(sourceSize: fullSize, state: state).crop.size
                    let scale = CGFloat(target) / max(out.width, out.height)
                    if scale < 1 { source = ImagePipeline.scaled(full, by: scale) }
                }
                var img = ImagePipeline.render(source: source, state: state)
                let extent = img.extent

                if options.watermark,
                   !options.watermarkText.trimmingCharacters(in: .whitespaces).isEmpty,
                   let wm = ImagePipeline.watermark(
                       text: options.watermarkText,
                       fontSize: max(extent.width, extent.height) * options.watermarkSize / 100,
                       opacity: options.watermarkOpacity / 100) {
                    let margin = min(extent.width, extent.height) * 0.03
                    let ww = wm.extent.width, wh = wm.extent.height
                    let origin: CGPoint
                    switch options.watermarkPosition {
                    case .bottomRight: origin = CGPoint(x: extent.maxX - ww - margin, y: margin)
                    case .bottomLeft: origin = CGPoint(x: margin, y: margin)
                    case .topRight: origin = CGPoint(x: extent.maxX - ww - margin, y: extent.maxY - wh - margin)
                    case .topLeft: origin = CGPoint(x: margin, y: extent.maxY - wh - margin)
                    case .center: origin = CGPoint(x: extent.midX - ww / 2, y: extent.midY - wh / 2)
                    }
                    img = wm.transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
                        .composited(over: img).cropped(to: extent)
                }

                let format: CIFormat = options.format == .tiff ? .RGBA16 : .RGBA8
                guard let cg = ImagePipeline.cgImage(img, colorSpace: options.colorProfile.space, format: format) else {
                    throw ExportError.render
                }
                guard let dest = CGImageDestinationCreateWithURL(url as CFURL, options.format.type.identifier as CFString, 1, nil) else {
                    throw ExportError.write
                }
                var props: [CFString: Any] = [:]
                if options.keepMetadata, let sourceURL,
                   let src = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
                   let meta = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                    for key in [kCGImagePropertyExifDictionary, kCGImagePropertyIPTCDictionary,
                                kCGImagePropertyGPSDictionary, kCGImagePropertyTIFFDictionary] {
                        if var dict = meta[key] as? [CFString: Any] {
                            dict.removeValue(forKey: kCGImagePropertyTIFFOrientation)
                            dict.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
                            dict.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
                            props[key] = dict
                        }
                    }
                }
                props[kCGImagePropertyOrientation] = 1
                if options.format.isLossy {
                    props[kCGImageDestinationLossyCompressionQuality] = options.quality / 100
                }
                CGImageDestinationAddImage(dest, cg, props as CFDictionary)
                guard CGImageDestinationFinalize(dest) else { throw ExportError.write }
                return url
            }
            DispatchQueue.main.async {
                self?.isExporting = false
                if case .success(let u) = result {
                    self?.hasUnexportedChanges = false
                    self?.lastExportURL = u
                }
                completion(result)
            }
        }
    }

    enum ExportError: LocalizedError {
        case render, write
        var errorDescription: String? {
            switch self {
            case .render: return "The photo couldn't be rendered."
            case .write: return "The file couldn't be saved. Check that you have permission to write there."
            }
        }
    }

    // MARK: Zoom

    func zoomIn() { zoom = min(8, zoom * 1.5) }
    func zoomOut() { zoom = max(1, zoom / 1.5) }
    func zoomToFit() { zoom = 1 }
}
