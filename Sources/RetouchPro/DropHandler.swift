import Foundation
import UniformTypeIdentifiers

/// Turns whatever was dropped on the window into a file Retouch Pro can open.
///
/// Different apps drag photos differently:
/// - Finder sends a file URL, often as a *file reference* (`file:///.file/id=…`) that has to be resolved to a real path.
/// - Photos, Lightroom, browsers and Messages often send only the image itself (JPEG/HEIC/PNG/TIFF data), no file.
enum DropHandler {
    static let acceptedTypes: [UTType] = [.fileURL, .image]

    /// Returns true if a usable item was found; `open` is called on the main thread with a local file URL.
    @discardableResult
    static func handle(_ providers: [NSItemProvider], open: @escaping (URL) -> Void,
                       failed: @escaping (String) -> Void = { _ in }) -> Bool {
        // Prefer a real file, so the original name, location and metadata are kept.
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let u = item as? URL {
                    url = u
                } else if let s = item as? String {
                    url = URL(string: s)
                }
                guard let resolved = url.map(resolve) else {
                    DispatchQueue.main.async { failed("That item couldn't be opened.") }
                    return
                }
                DispatchQueue.main.async { open(resolved) }
            }
            return true
        }

        // Otherwise take the image data itself.
        for provider in providers {
            let types = provider.registeredTypeIdentifiers.compactMap(UTType.init)
            guard let type = preferredImageType(types) else { continue }
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { tempURL, error in
                // The temporary file is deleted when this block returns, so copy it first.
                guard let tempURL, let copy = try? keepCopy(of: tempURL, type: type, suggestedName: provider.suggestedName) else {
                    DispatchQueue.main.async { failed("The dropped image couldn't be read.") }
                    return
                }
                DispatchQueue.main.async { open(copy) }
            }
            return true
        }
        return false
    }

    /// File reference URLs (`/.file/id=…`) → normal file paths.
    static func resolve(_ url: URL) -> URL {
        guard url.isFileURL else { return url }
        return (url as NSURL).filePathURL ?? url
    }

    /// Best format to ask for: originals (RAW, HEIC, JPEG) before re-encoded ones (TIFF, PNG).
    static func preferredImageType(_ types: [UTType]) -> UTType? {
        let order: [UTType] = [.rawImage, .heic, .jpeg, .png, .tiff, .image]
        for wanted in order {
            if let t = types.first(where: { $0.conforms(to: wanted) }) { return t }
        }
        return nil
    }

    private static func keepCopy(of url: URL, type: UTType, suggestedName: String?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Retouch Pro Drops", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var name = (suggestedName?.isEmpty == false ? suggestedName! : url.deletingPathExtension().lastPathComponent)
        if name.isEmpty { name = "Dropped Photo" }
        let ext = url.pathExtension.isEmpty ? (type.preferredFilenameExtension ?? "jpg") : url.pathExtension
        let dest = dir.appendingPathComponent((name as NSString).deletingPathExtension).appendingPathExtension(ext)
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }
}
