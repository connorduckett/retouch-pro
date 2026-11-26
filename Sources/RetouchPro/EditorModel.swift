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
            if tool != oldValue && (tool == .crop || oldValue == .crop || showMaskOverlay) { scheduleRender() }
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

    // MARK: Library integration

    enum Mode { case library, edit }
    @Published var mode: Mode = Library.shared.photos.isEmpty ? .edit : .library
    /// The library photo being edited (edits are saved to it automatically).
    @Published private(set) var currentPhotoID: UUID?
    private var persistWork: DispatchWorkItem?

    /// The album currently chosen in the library, if any (imports go there).
    var currentAlbumID: UUID? {
        if case .album(let id) = Library.shared.selection { return id }
        return nil
    }

    func presentOpenPanel() {
        let ids = Library.shared.presentImportPanel(intoAlbum: currentAlbumID)
        if ids.count == 1 { openPhoto(ids[0]) }
        else if ids.count > 1 { mode = .library }
    }

    /// Opens files dropped or chosen outside the library: they're added to it first.
    func open(url rawURL: URL) {
        openFiles([rawURL])
    }

    func openFiles(_ urls: [URL]) {
        let ids = Library.shared.importPhotos(urls, intoAlbum: mode == .library ? currentAlbumID : nil)
        if ids.count == 1 { openPhoto(ids[0]) }
        else if ids.count > 1 { mode = .library }
        else if let first = urls.first {
            loadError = "Retouch Pro couldn't open “\(first.lastPathComponent)”. Try a JPEG, PNG, HEIC, TIFF or camera RAW file."
        }
    }

    /// Opens a library photo in the editor with its saved edits.
    func openPhoto(_ id: UUID) {
        guard let photo = Library.shared.photo(id) else { return }
        if id == currentPhotoID, hasImage { mode = .edit; return }
        guard let url = Library.shared.url(for: photo) else {
            loadError = "“\(photo.name)” can’t be found. It may have been moved or deleted."
            return
        }
        flushEdits()
        mode = .edit
        load(url: url, photoID: id, initialState: photo.edits ?? EditState())
    }

    /// Moves to the previous/next photo in the current library collection.
    func stepPhoto(_ delta: Int) {
        let photos = Library.shared.photos(in: Library.shared.selection)
        guard !photos.isEmpty else { return }
        let i = photos.firstIndex { $0.id == currentPhotoID } ?? -1
        let j = min(max(0, i + delta), photos.count - 1)
        if j != i { openPhoto(photos[j].id) }
    }

    /// Saves the current photo's edits to the library (soon, coalescing rapid changes).
    private func persistEdits() {
        guard currentPhotoID != nil else { return }
        persistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushEdits() }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// Saves now, and refreshes the photo's library thumbnail to show the edits.
    func flushEdits() {
        persistWork?.cancel()
        persistWork = nil
        guard let id = currentPhotoID, let proxy = sourceProxy else { return }
        let state = self.state
        let before = Library.shared.photo(id)?.edits ?? EditState()
        Library.shared.saveEdits(state, for: id)
        guard before != state else { return }
        workQueue.async {
            if state.isIdentity {
                Library.shared.storeEditedThumbnail(nil, for: id)
                return
            }
            let small = ImagePipeline.scaled(proxy, toMaxDimension: 420)
            let cg = ImagePipeline.cgImage(ImagePipeline.render(source: small, state: state), colorSpace: ImagePipeline.sRGB)
            Library.shared.storeEditedThumbnail(cg, for: id)
        }
    }

    private func load(url: URL, photoID: UUID?, initialState: EditState) {
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
                self.currentPhotoID = photoID
                self.history = [initialState]
                self.historyIndex = 0
                self.hasUnexportedChanges = false
                self.zoom = 1
                self.tool = .adjust
                self.lookThumbnails = [:]
                self.preview = nil
                self.state = initialState
                self.selectedLayerID = nil
                self.isLoading = false
                self.scheduleRender()
                self.buildLookThumbnails()
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
            }
        }
    }

    private func confirmDiscardIfNeeded() -> Bool {
        guard hasImage, hasUnexportedChanges, currentPhotoID == nil else { return true }
        if UserDefaults.standard.object(forKey: SettingsKey.confirmDiscard) != nil,
           !UserDefaults.standard.bool(forKey: SettingsKey.confirmDiscard) { return true }
        let alert = NSAlert()
        alert.messageText = "Discard your edits?"
        alert.informativeText = "You haven’t exported “\(fileName)” since your last change."
        alert.addButton(withTitle: "Discard Edits")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Asks before restarting for an update when there are unexported edits.
    func confirmQuitForUpdate() -> Bool {
        guard hasImage, hasUnexportedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "Restart to update?"
        alert.informativeText = "Retouch Pro will close to install the update. Your edits to “\(fileName)” haven’t been exported and will be lost."
        alert.addButton(withTitle: "Update Anyway")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func close() {
        guard confirmDiscardIfNeeded() else { return }
        flushEdits()
        currentPhotoID = nil
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
        persistEdits()
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
        persistEdits()
    }

    func redo() {
        guard canRedo else { return }
        historyIndex += 1
        state = history[historyIndex]
        hasUnexportedChanges = true
        persistEdits()
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

    /// Simple statistics of the original photo, measured the same way the Signature target was.
    private struct PhotoStats { var p1, p50, p99, saturation, warmth: Double }

    private func originalStats() -> PhotoStats? {
        guard let cg = originalPreview?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = 200, h = max(1, Int(200.0 * Double(cg.height) / Double(cg.width)))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: ImagePipeline.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var lum: [Double] = []; lum.reserveCapacity(w * h)
        var sat = 0.0, warm = 0.0, warmN = 0.0
        for i in 0..<(w * h) {
            let r = Double(px[i * 4]), g = Double(px[i * 4 + 1]), b = Double(px[i * 4 + 2])
            let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
            lum.append(l)
            let mx = max(r, g, b), mn = min(r, g, b)
            sat += mx > 0 ? (mx - mn) / mx : 0
            if l > 40 && l < 220 { warm += r - b; warmN += 1 }
        }
        lum.sort()
        func q(_ p: Double) -> Double { lum[Int(p * Double(lum.count - 1))] / 255 }
        return PhotoStats(p1: q(0.01), p50: q(0.5), p99: q(0.99),
                          saturation: sat / Double(w * h), warmth: warmN > 0 ? warm / warmN : 0)
    }

    func autoEnhance() {
        guard let st = originalStats() else { return }
        let style = AutoEnhanceStyle(rawValue: UserDefaults.standard.string(forKey: SettingsKey.autoStyle) ?? "") ?? .signature
        var a = Adjustments()

        switch style {
        case .natural:
            if st.p50 > 0.02 {
                let ev = log2(pow(0.46 / st.p50, 2.2))
                a.exposure = max(-60, min(60, ev / 2 * 100 * 0.6))
            }
            if st.p99 < 0.96 { a.whites = min(50, (0.97 - st.p99) * 250) }
            if st.p1 > 0.04 { a.blacks = max(-50, -(st.p1 - 0.02) * 300) }
            if st.p99 > 0.985 { a.highlights = -25 }
            if st.p1 < 0.02 { a.shadows = 15 }
            a.contrast = 8
            a.vibrance = 22
            a.clarity = 8

        case .signature:
            // Target profile measured from a professional wedding & portrait portfolio:
            // bright midtones (median ≈ 0.55), softly lifted blacks (1st percentile ≈ 0.077),
            // clean but unclipped whites (99th ≈ 0.96), gentle saturation (≈ 0.29) and a warm balance.
            let target = PhotoStats(p1: 0.077, p50: 0.55, p99: 0.958, saturation: 0.29, warmth: 19)
            if st.p50 > 0.02 {
                let ev = log2(pow(target.p50 / st.p50, 2.2)) * 0.75
                a.exposure = max(-60, min(70, ev / 2 * 100))
            }
            a.shadows = 22
            a.contrast = -6
            if st.p99 > 0.985 { a.highlights = -35 } else { a.highlights = -12 }
            if st.p99 < 0.94 { a.whites = min(45, (target.p99 - st.p99) * 260) }
            // Soft, matte blacks instead of crushed ones.
            a.fade = max(8, min(32, (target.p1 - st.p1) * 380 + 10))
            if st.p1 > 0.12 { a.blacks = max(-35, -(st.p1 - target.p1) * 200) }
            // Gentle color: pull saturation toward the target, with vibrance protecting skin.
            let satDelta = target.saturation - st.saturation
            a.saturation = max(-25, min(15, satDelta * 120))
            a.vibrance = 12
            // Warm balance. One Temperature step shifts (R−B) by ≈ 0.35 levels.
            if st.saturation > 0.04 {
                a.temperature = max(-25, min(30, (target.warmth - st.warmth) / 0.35 * 0.6))
            }
            a.tint = 3
            a.clarity = -4
        }

        apply {
            let keep = $0.adjustments
            $0.adjustments = a
            // Keep the user's detail, retouch & effects choices.
            $0.adjustments.sharpness = keep.sharpness
            $0.adjustments.noiseReduction = keep.noiseReduction
            $0.adjustments.shadowRemoval = keep.shadowRemoval
            $0.adjustments.sunSpotRemoval = keep.sunSpotRemoval
            $0.adjustments.skinSpotRemoval = keep.skinSpotRemoval
            $0.adjustments.vignette = keep.vignette
            $0.adjustments.grain = keep.grain
            if style == .natural { $0.adjustments.fade = keep.fade }
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

    // MARK: Coordinate mapping

    /// Displayed photo (normalized, top-left origin) → original photo (normalized by longest side, y-up).
    func displayToSource(_ p: CGPoint) -> CGPoint {
        guard fullSize != .zero else { return .zero }
        let g = ImagePipeline.geometry(sourceSize: fullSize, state: state)
        let out = CGPoint(x: g.crop.minX + p.x * g.crop.width, y: g.crop.minY + (1 - p.y) * g.crop.height)
        let src = out.applying(g.transform.inverted())
        let maxDim = max(fullSize.width, fullSize.height)
        return CGPoint(x: src.x / maxDim, y: src.y / maxDim)
    }

    /// Original photo (normalized, y-up) → displayed photo (normalized, top-left origin).
    func sourceToDisplay(_ p: CGPoint) -> CGPoint {
        guard fullSize != .zero else { return .zero }
        let g = ImagePipeline.geometry(sourceSize: fullSize, state: state)
        let maxDim = max(fullSize.width, fullSize.height)
        let out = CGPoint(x: p.x * maxDim, y: p.y * maxDim).applying(g.transform)
        return CGPoint(x: (out.x - g.crop.minX) / g.crop.width, y: 1 - (out.y - g.crop.minY) / g.crop.height)
    }

    /// Screen length (points, at the given display width) → original-photo length (normalized).
    func displayLengthToSource(_ length: CGFloat, displayWidth: CGFloat) -> Double {
        guard fullSize != .zero, displayWidth > 0 else { return 0 }
        let g = ImagePipeline.geometry(sourceSize: fullSize, state: state)
        let out = length / displayWidth * g.crop.width
        let t = g.transform.inverted()
        let v = CGPoint(x: out, y: 0).applying(CGAffineTransform(a: t.a, b: t.b, c: t.c, d: t.d, tx: 0, ty: 0))
        return hypot(v.x, v.y) / max(fullSize.width, fullSize.height)
    }

    /// Original-photo length (normalized) → screen length at the given display width.
    func sourceLengthToDisplay(_ length: Double, displayWidth: CGFloat) -> CGFloat {
        guard fullSize != .zero else { return 0 }
        let g = ImagePipeline.geometry(sourceSize: fullSize, state: state)
        let maxDim = max(fullSize.width, fullSize.height)
        let t = g.transform
        let v = CGPoint(x: length * maxDim, y: 0).applying(CGAffineTransform(a: t.a, b: t.b, c: t.c, d: t.d, tx: 0, ty: 0))
        return hypot(v.x, v.y) / g.crop.width * displayWidth
    }

    // MARK: Heal

    @Published private(set) var isHealing = false

    /// Heals a click (one point) or a brush stroke. Points are normalized in the displayed photo (top-left origin).
    func heal(displayPoints: [CGPoint], displaySize: CGSize) {
        guard let engine = healEngine, fullSize != .zero, displaySize.width > 0, !displayPoints.isEmpty else { return }
        let src = displayPoints.map(displayToSource)
        let aspect = fullSize.width / max(fullSize.width, fullSize.height)
        let aspectH = fullSize.height / max(fullSize.width, fullSize.height)
        let inside = src.filter { $0.x >= 0 && $0.y >= 0 && $0.x <= aspect && $0.y <= aspectH }
        guard !inside.isEmpty else { return }
        let radius = displayLengthToSource(healBrushSize / 2, displayWidth: displaySize.width)
        isHealing = true
        workQueue.async { [weak self] in
            let spot = engine.heal(points: inside, radius: radius)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isHealing = false
                if let spot { self.apply { $0.heals.append(spot) } }
            }
        }
    }

    /// Outlines of healed areas in display coordinates (normalized, top-left origin) with on-screen radius.
    func healMarkers(displaySize: CGSize) -> [([CGPoint], CGFloat)] {
        guard fullSize != .zero else { return [] }
        return state.heals.map { spot in
            let pts = spot.points.compactMap { $0.count == 2 ? sourceToDisplay(CGPoint(x: $0[0], y: $0[1])) : nil }
            return (pts, sourceLengthToDisplay(spot.radius, displayWidth: displaySize.width))
        }
    }

    // MARK: Layers

    @Published var selectedLayerID: UUID? {
        didSet { if selectedLayerID != oldValue { editingMask = false; if showMaskOverlay { scheduleRender() } } }
    }
    /// For text/shape/path layers: whether canvas clicks edit the mask instead of the content.
    @Published var editingMask = false
    @Published var showMaskOverlay = false {
        didSet { if showMaskOverlay != oldValue { scheduleRender() } }
    }
    @Published var maskBrushSize: Double = 60
    @Published var maskErase = false
    /// When true, clicks on the canvas add pen-tool points to the selected path layer.
    @Published var penActive = true

    var selectedLayerIndex: Int? {
        guard let id = selectedLayerID else { return nil }
        return state.layers.firstIndex { $0.id == id }
    }

    var selectedLayer: Layer? {
        selectedLayerIndex.map { state.layers[$0] }
    }

    /// Live edit of the selected layer (call `commit()` when the gesture ends).
    func updateSelectedLayer(_ change: (inout Layer) -> Void) {
        guard let i = selectedLayerIndex else { return }
        var s = state
        change(&s.layers[i])
        state = s
    }

    // MARK: Automatic selections

    /// Lives on `workQueue` only.
    private var autoMasker: AutoMasker?
    private var autoMaskerToken: UUID?
    @Published private(set) var isDetecting = false
    @Published var autoMaskMessage: String?
    /// When on, the canvas paints/erases to touch up an automatic selection instead of picking people.
    @Published var refineAutoMask = false

    /// Detects people / sky / subject / background and sets it as the layer's mask.
    func applyAutoMask(_ mode: MaskMode, toLayer id: UUID? = nil) {
        guard mode.isAutomatic, let proxy = sourceProxy, let layerID = id ?? selectedLayerID else { return }
        let token = loadToken
        let current = state.layers.first { $0.id == layerID }?.mask
        let excluded = current?.mode == mode ? current?.autoExcluded ?? [] : []
        let sensitivity = current?.autoSensitivity ?? 50
        isDetecting = true
        autoMaskMessage = nil
        workQueue.async { [weak self] in
            guard let self else { return }
            if self.autoMasker == nil || self.autoMaskerToken != token {
                self.autoMasker = AutoMasker(source: proxy)
                self.autoMaskerToken = token
            }
            let result = self.autoMasker?.mask(mode, excluding: excluded, sensitivity: sensitivity)
            DispatchQueue.main.async {
                self.isDetecting = false
                guard self.loadToken == token, let i = self.state.layers.firstIndex(where: { $0.id == layerID }) else { return }
                guard let result else {
                    self.autoMaskMessage = "Retouch Pro couldn’t analyze this photo."
                    return
                }
                if mode.hasInstances && result.instanceCount == 0 {
                    self.autoMaskMessage = mode == .people ? "No people were found in this photo." : "No clear subject was found in this photo."
                }
                self.apply {
                    $0.layers[i].mask.mode = mode
                    $0.layers[i].mask.autoMaskPNG = result.png
                    $0.layers[i].mask.autoExcluded = excluded
                    $0.layers[i].mask.autoInstanceCount = result.instanceCount
                }
                self.showMaskOverlay = true
            }
        }
    }

    /// Clicking a person or subject on the photo removes it from (or adds it back to) the selection.
    func toggleAutoInstance(atDisplayPoint point: CGPoint) {
        guard let layer = selectedLayer, layer.mask.mode.hasInstances, fullSize != .zero else { return }
        let mode = layer.mask.mode, layerID = layer.id, token = loadToken
        let src = displayToSource(point)
        let maxDim = max(fullSize.width, fullSize.height)
        let fx = Double(src.x * maxDim / fullSize.width)
        let fyTop = 1 - Double(src.y * maxDim / fullSize.height)
        var excluded = layer.mask.autoExcluded
        isDetecting = true
        workQueue.async { [weak self] in
            guard let self, let masker = self.autoMasker, self.autoMaskerToken == token else {
                DispatchQueue.main.async { self?.isDetecting = false }
                return
            }
            guard let hit = masker.instance(mode, atX: fx, y: fyTop) else {
                DispatchQueue.main.async {
                    self.isDetecting = false
                    self.autoMaskMessage = "Click directly on a \(mode == .people ? "person" : "subject") to include or exclude them."
                }
                return
            }
            if let k = excluded.firstIndex(of: hit) { excluded.remove(at: k) } else { excluded.append(hit) }
            let result = masker.mask(mode, excluding: excluded)
            DispatchQueue.main.async {
                self.isDetecting = false
                self.autoMaskMessage = nil
                guard let result, let i = self.state.layers.firstIndex(where: { $0.id == layerID }) else { return }
                self.apply {
                    $0.layers[i].mask.autoMaskPNG = result.png
                    $0.layers[i].mask.autoExcluded = excluded
                }
            }
        }
    }

    func includeAllAutoInstances() {
        guard let layer = selectedLayer else { return }
        updateSelectedLayer { $0.mask.autoExcluded = [] }
        applyAutoMask(layer.mask.mode)
    }

    enum NewLayer {
        case auto(MaskMode)
        case adjustment, removeShadows, removeSunSpots, smoothSkinSpots, brightenFaces
        case text, shape(ShapeKind), path
    }

    func addLayer(_ kind: NewLayer) {
        var layer: Layer
        var autoMode: MaskMode?
        switch kind {
        case .auto(let mode):
            layer = Layer(name: mode.rawValue, kind: .adjustment)
            layer.mask.mode = mode
            layer.mask.feather = 20
            autoMode = mode
        case .adjustment:
            layer = Layer(name: "Adjustment", kind: .adjustment)
        case .removeShadows:
            layer = Layer(name: "Remove Shadows", kind: .adjustment)
            layer.adjustments.shadowRemoval = 70
            layer.adjustments.exposure = 10
            layer.adjustments.temperature = 6
            layer.mask.mode = .brush
        case .removeSunSpots:
            layer = Layer(name: "Tame Sun Spots", kind: .adjustment)
            layer.adjustments.sunSpotRemoval = 75
            layer.adjustments.exposure = -12
            layer.adjustments.saturation = 5
            layer.mask.mode = .brush
        case .smoothSkinSpots:
            layer = Layer(name: "Fade Skin Spots", kind: .adjustment)
            layer.adjustments.skinSpotRemoval = 75
            layer.mask.mode = .brush
        case .brightenFaces:
            layer = Layer(name: "Brighten", kind: .adjustment)
            layer.adjustments.exposure = 18
            layer.adjustments.shadows = 15
            layer.mask.mode = .radial
            layer.mask.feather = 60
            let c = displayToSource(CGPoint(x: 0.5, y: 0.4))
            layer.mask.center = [c.x, c.y]
        case .text:
            layer = Layer(name: "Text", kind: .text)
            layer.frame = CGRect(x: 0.15, y: 0.42, width: 0.7, height: 0.16)
        case .shape(let shape):
            layer = Layer(name: shape.rawValue, kind: .shape)
            layer.shapeKind = shape
            layer.frame = shape == .line ? CGRect(x: 0.25, y: 0.48, width: 0.5, height: 0.04)
                                         : CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3)
            if shape == .line { layer.strokeEnabled = true; layer.strokeColor = .white; layer.strokeWidth = 0.5 }
        case .path:
            layer = Layer(name: "Path", kind: .path)
            layer.fillEnabled = true
            layer.strokeEnabled = true
            layer.strokeColor = .white
            layer.fillColor = RGBAColor(r: 1, g: 1, b: 1, a: 0.25)
            penActive = true
        }
        // Avoid duplicate names.
        let base = layer.name
        var n = 2
        while state.layers.contains(where: { $0.name == layer.name }) { layer.name = "\(base) \(n)"; n += 1 }

        // Insert above the selected layer (or on top).
        let insertAt = selectedLayerIndex.map { $0 + 1 } ?? state.layers.count
        apply { $0.layers.insert(layer, at: insertAt) }
        selectedLayerID = layer.id
        if tool != .layers { tool = .layers }
        if let autoMode {
            refineAutoMask = false
            applyAutoMask(autoMode, toLayer: layer.id)
        }
    }

    func deleteSelectedLayer() {
        guard let i = selectedLayerIndex else { return }
        apply { $0.layers.remove(at: i) }
        if state.layers.isEmpty { selectedLayerID = nil }
        else { selectedLayerID = state.layers[max(0, i - 1)].id }
    }

    func duplicateSelectedLayer() {
        guard let i = selectedLayerIndex else { return }
        var copy = state.layers[i]
        copy.id = UUID()
        copy.name += " copy"
        apply { $0.layers.insert(copy, at: i + 1) }
        selectedLayerID = copy.id
    }

    func moveSelectedLayer(up: Bool) {
        guard let i = selectedLayerIndex else { return }
        let j = up ? i + 1 : i - 1
        guard j >= 0, j < state.layers.count else { return }
        apply { $0.layers.swapAt(i, j) }
    }

    func toggleVisibility(_ id: UUID) {
        guard let i = state.layers.firstIndex(where: { $0.id == id }) else { return }
        apply { $0.layers[i].visible.toggle() }
    }

    /// Adds a painted mask stroke to the selected layer. Points are display-normalized (top-left origin).
    func addMaskStroke(displayPoints: [CGPoint], displaySize: CGSize) {
        guard let i = selectedLayerIndex, !displayPoints.isEmpty else { return }
        let pts = displayPoints.map(displayToSource).map { [Double($0.x), Double($0.y)] }
        let r = displayLengthToSource(maskBrushSize / 2, displayWidth: displaySize.width)
        apply {
            if !$0.layers[i].mask.mode.isAutomatic { $0.layers[i].mask.mode = .brush }
            $0.layers[i].mask.strokes.append(MaskStroke(points: pts, radius: r, erase: maskErase))
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
        let overlayLayer = (tool == .layers && showMaskOverlay) ? selectedLayerID : nil

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
            let output = ImagePipeline.render(source: source, state: state, ignoreCrop: ignoreCrop,
                                              maskOverlayLayer: overlayLayer)
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

    /// Starts the Export window from the user's saved defaults (Settings ▸ Export).
    func loadExportDefaults() {
        let d = UserDefaults.standard
        if let f = d.string(forKey: SettingsKey.exportFormat).flatMap(ExportOptions.Format.init(rawValue:)) {
            exportOptions.format = f
        }
        if d.object(forKey: SettingsKey.exportQuality) != nil {
            exportOptions.quality = d.double(forKey: SettingsKey.exportQuality)
        }
        if let c = d.string(forKey: SettingsKey.exportColor).flatMap(ExportOptions.ColorProfile.init(rawValue:)) {
            exportOptions.colorProfile = c
        }
        if d.object(forKey: SettingsKey.keepMetadata) != nil {
            exportOptions.keepMetadata = d.bool(forKey: SettingsKey.keepMetadata)
        }
    }
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
