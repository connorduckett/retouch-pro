import AppKit
import CoreImage
import Foundation

/// Which parts of a photo's settings a preset carries.
enum PresetGroup: String, Codable, CaseIterable, Identifiable {
    case light = "Light"
    case color = "Color"
    case retouch = "Retouch"
    case detail = "Detail"
    case effects = "Effects"
    case look = "Look"
    case crop = "Crop & Rotate"

    var id: String { rawValue }

    /// Crop is photo-specific, so it's off unless you ask for it.
    static let defaults: Set<PresetGroup> = [.light, .color, .retouch, .detail, .effects, .look]
}

/// A saved set of settings that can be applied to any number of photos.
struct Preset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var groups: Set<PresetGroup>
    var adjustments = Adjustments()
    var lookID: String?
    var lookAmount: Double = 100
    var crop: CGRect = EditState.fullCrop
    var straighten: Double = 0
    var quarterTurns = 0
    var flipHorizontal = false
    var flipVertical = false
    var created = Date()

    init(name: String, from state: EditState, groups: Set<PresetGroup>) {
        self.name = name
        self.groups = groups
        adjustments = state.adjustments
        lookID = state.lookID
        lookAmount = state.lookAmount
        crop = state.crop
        straighten = state.straighten
        quarterTurns = state.quarterTurns
        flipHorizontal = state.flipHorizontal
        flipVertical = state.flipVertical
    }

    /// Copies the chosen groups onto a photo's settings, leaving everything else (heals, layers,
    /// other groups) exactly as it was.
    func apply(to state: EditState) -> EditState {
        var s = state
        let a = adjustments
        if groups.contains(.light) {
            s.adjustments.exposure = a.exposure; s.adjustments.contrast = a.contrast
            s.adjustments.highlights = a.highlights; s.adjustments.shadows = a.shadows
            s.adjustments.whites = a.whites; s.adjustments.blacks = a.blacks
        }
        if groups.contains(.color) {
            s.adjustments.temperature = a.temperature; s.adjustments.tint = a.tint
            s.adjustments.vibrance = a.vibrance; s.adjustments.saturation = a.saturation
        }
        if groups.contains(.retouch) {
            s.adjustments.shadowRemoval = a.shadowRemoval; s.adjustments.sunSpotRemoval = a.sunSpotRemoval
            s.adjustments.skinSpotRemoval = a.skinSpotRemoval
        }
        if groups.contains(.detail) {
            s.adjustments.clarity = a.clarity; s.adjustments.sharpness = a.sharpness
            s.adjustments.noiseReduction = a.noiseReduction
        }
        if groups.contains(.effects) {
            s.adjustments.vignette = a.vignette; s.adjustments.grain = a.grain; s.adjustments.fade = a.fade
        }
        if groups.contains(.look) {
            s.lookID = lookID; s.lookAmount = lookAmount
        }
        if groups.contains(.crop) {
            s.crop = crop; s.straighten = straighten; s.quarterTurns = quarterTurns
            s.flipHorizontal = flipHorizontal; s.flipVertical = flipVertical
        }
        return s
    }

    var summary: String {
        PresetGroup.allCases.filter(groups.contains).map(\.rawValue).joined(separator: " · ")
    }
}

/// Your presets, saved in ~/Library/Application Support/Retouch Pro/Presets.json.
final class PresetStore: ObservableObject {
    static let shared = PresetStore()
    @Published private(set) var presets: [Preset] = []

    private var url: URL { Library.shared.directory.appendingPathComponent("Presets.json") }

    init() {
        if let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([Preset].self, from: data) {
            presets = list
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(presets) { try? data.write(to: url, options: .atomic) }
    }

    func add(_ preset: Preset) {
        presets.removeAll { $0.name == preset.name }   // same name replaces (update a preset)
        presets.append(preset)
        presets.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        save()
    }

    func delete(_ id: UUID) {
        presets.removeAll { $0.id == id }
        save()
    }

    func rename(_ id: UUID, to name: String) {
        guard let i = presets.firstIndex(where: { $0.id == id }), !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        presets[i].name = name
        save()
    }
}

// MARK: - Batch editing

extension EditorModel {
    /// The photos a batch action applies to: the library selection, or the photo being edited.
    var batchTargets: [UUID] {
        let lib = Library.shared
        if mode == .library {
            return lib.visiblePhotos().map(\.id).filter(lib.gridSelection.contains)
        }
        return currentPhotoID.map { [$0] } ?? []
    }

    /// Applies a preset to many photos at once (non-destructive: it only changes their saved settings).
    func applyPreset(_ preset: Preset, to ids: [UUID]) {
        applyToPhotos(ids) { preset.apply(to: $0) }
        batchMessage = "Applied “\(preset.name)” to \(ids.count) photo\(ids.count == 1 ? "" : "s")."
    }

    /// Copies the selected (or open) photo's settings for pasting onto others.
    func copySettings() {
        let lib = Library.shared
        let state: EditState
        if mode == .edit, hasImage {
            state = self.state
        } else if let id = batchTargets.first, let photo = lib.photo(id) {
            state = photo.edits ?? EditState()
        } else { return }
        settingsClipboard = Preset(name: "Copied settings", from: state, groups: PresetGroup.defaults)
        hasSettingsClipboard = true
        batchMessage = "Copied settings. Select photos and choose Paste Settings (⇧⌘V)."
    }

    func pasteSettings(to ids: [UUID]) {
        guard let clip = settingsClipboard else { return }
        applyToPhotos(ids) { clip.apply(to: $0) }
        batchMessage = "Pasted settings onto \(ids.count) photo\(ids.count == 1 ? "" : "s")."
    }

    func resetSettings(of ids: [UUID]) {
        applyToPhotos(ids) { _ in EditState() }
        batchMessage = "Reset \(ids.count) photo\(ids.count == 1 ? "" : "s") to the original."
    }

    private func applyToPhotos(_ ids: [UUID], _ change: (EditState) -> EditState) {
        let lib = Library.shared
        for id in ids {
            if id == currentPhotoID, hasImage {
                apply { $0 = change($0) }
                flushEdits()
            } else if let photo = lib.photo(id) {
                lib.saveEdits(change(photo.edits ?? EditState()), for: id)
                refreshThumbnail(id)
            }
        }
    }

    /// Re-renders a photo's library thumbnail with its edits, from the camera's embedded preview.
    func refreshThumbnail(_ id: UUID) {
        let lib = Library.shared
        guard let photo = lib.photo(id), let url = lib.url(for: photo) else { return }
        let state = photo.edits
        Self.thumbnailQueue.addOperation {
            guard let state, !state.isIdentity else {
                lib.storeEditedThumbnail(nil, for: id)
                return
            }
            guard let cg = FastPreview.image(at: url, maxPixelSize: 640) else { return }
            let src = CIImage(cgImage: cg)
            let out = ImagePipeline.cgImage(ImagePipeline.render(source: src, state: state), colorSpace: ImagePipeline.sRGB)
            lib.storeEditedThumbnail(out, for: id)
        }
    }

    static let thumbnailQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .utility
        return q
    }()

    // MARK: Batch export

    /// Exports many photos with their edits into a folder, one at a time (RAW files are large).
    func exportBatch(_ ids: [UUID], to folder: URL, progress: @escaping (Int) -> Void,
                     completion: @escaping (_ written: Int, _ failed: [String]) -> Void) {
        flushEdits()
        let lib = Library.shared
        let options = exportOptions
        let current = currentPhotoID
        let currentState = state
        let jobs: [(URL, EditState, String)] = ids.compactMap { id in
            guard let photo = lib.photo(id), let url = lib.url(for: photo) else { return nil }
            let state = id == current ? currentState : (photo.edits ?? EditState())
            return (url, state, photo.name)
        }
        batchCancelled = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var written = 0
            var failed: [String] = []
            var used = Set<String>()
            for (i, job) in jobs.enumerated() {
                if self?.batchCancelled == true { break }
                autoreleasepool {
                    let base = (job.2 as NSString).deletingPathExtension
                    var name = "\(base)-edited.\(options.format.ext)"
                    var n = 2
                    while used.contains(name) || FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
                        name = "\(base)-edited-\(n).\(options.format.ext)"; n += 1
                    }
                    used.insert(name)
                    do {
                        guard let full = ImagePipeline.load(url: job.0) else { throw ExportError.render }
                        try Self.renderExport(full: full, sourceURL: job.0, state: job.1, options: options,
                                              to: folder.appendingPathComponent(name))
                        written += 1
                    } catch {
                        failed.append(job.2)
                    }
                }
                DispatchQueue.main.async { progress(i + 1) }
            }
            DispatchQueue.main.async { completion(written, failed) }
        }
    }

    func cancelBatchExport() { batchCancelled = true }
}
