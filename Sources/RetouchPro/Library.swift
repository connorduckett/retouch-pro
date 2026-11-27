import AppKit
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum PhotoFlag: String, Codable {
    case pick, reject
}

enum FlagFilter: String, CaseIterable, Identifiable {
    case all = "All", picks = "Picks", unflagged = "Unflagged", rejected = "Rejected"
    var id: String { rawValue }
    func includes(_ flag: PhotoFlag?) -> Bool {
        switch self {
        case .all: return true
        case .picks: return flag == .pick
        case .unflagged: return flag == nil
        case .rejected: return flag == .reject
        }
    }
}

struct LibraryPhoto: Codable, Identifiable, Equatable {
    var id = UUID()
    var path: String
    var bookmark: Data?
    var added = Date()
    /// Saved edits (nil = untouched). Edits are kept here, so the original file is never changed.
    var edits: EditState?
    var editedAt: Date?
    /// Pick (flagged), Rejected, or nil for unflagged.
    var flag: PhotoFlag?
    /// Problems found by the Culling Assistant (PhotoIssue raw values).
    var issues: [String]?

    var issueList: [PhotoIssue] { (issues ?? []).compactMap(PhotoIssue.init(rawValue:)) }
    var hasDefects: Bool { issueList.contains { $0.isDefect } }

    var name: String { (path as NSString).lastPathComponent }
    var isEdited: Bool { edits.map { !$0.isIdentity } ?? false }
}

struct Album: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var photoIDs: [UUID] = []
    /// The whole shoot kept next to its category albums (e.g. "All Photos" after culling). It's not a
    /// category: sorting photos into categories never takes them out of it.
    var holdsEverything: Bool?
}

struct Folder: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var albums: [Album] = []
    var expanded = true
    /// The folder this one sits inside (nil = top level). Folders can nest as deep as you like.
    var parentID: UUID?

    /// Albums you sort photos between (keys 1–9, Move to).
    var categoryAlbums: [Album] { albums.filter { $0.holdsEverything != true } }
}

enum LibrarySelection: Hashable {
    case all
    case edited
    case picks
    case rejected
    case needsReview
    case folder(UUID)
    case album(UUID)
}

/// The photo catalog: every imported photo with its edits, plus folders that hold albums.
/// Saved as JSON in ~/Library/Application Support/Retouch Pro/.
final class Library: ObservableObject {
    static let shared = Library()

    @Published private(set) var photos: [LibraryPhoto] = []
    @Published private(set) var folders: [Folder] = []
    @Published var selection: LibrarySelection = .all {
        didSet { if selection != oldValue { gridSelection = [] } }
    }
    /// Show only picks / unflagged / rejected within the current collection.
    @Published var flagFilter: FlagFilter = .all
    /// Photos selected in the grid.
    @Published var gridSelection: Set<UUID> = []
    /// Where a Shift-click range starts (the last photo clicked without Shift).
    var gridAnchor: UUID?
    /// The photo a Shift-arrow extension is currently at.
    var gridCursor: UUID?
    /// Bumped when a photo's thumbnail changes so grids reload it.
    @Published private(set) var thumbnailVersion: [UUID: Int] = [:]

    private struct Stored: Codable {
        var photos: [LibraryPhoto]
        var folders: [Folder]
    }

    let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Retouch Pro", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("Thumbnails"), withIntermediateDirectories: true)
        return dir
    }()
    private var fileURL: URL { directory.appendingPathComponent("Library.json") }
    private var saveWork: DispatchWorkItem?
    private let ioQueue = DispatchQueue(label: "retouchpro.library", qos: .utility)

    init() { load() }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            // Never overwrite a library we couldn't read: keep a copy so nothing is lost.
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            try? FileManager.default.copyItem(at: fileURL, to: directory.appendingPathComponent("Library-unreadable-\(stamp).json"))
            return
        }
        photos = stored.photos
        folders = stored.folders
    }

    /// Saves shortly after the last change (coalesces bursts of edits).
    func setNeedsSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        let stored = Stored(photos: photos, folders: folders)
        let url = fileURL
        ioQueue.async {
            guard let data = try? JSONEncoder().encode(stored) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: Lookup

    func photo(_ id: UUID) -> LibraryPhoto? { photos.first { $0.id == id } }

    func album(_ id: UUID) -> Album? {
        for f in folders { if let a = f.albums.first(where: { $0.id == id }) { return a } }
        return nil
    }

    func folder(containingAlbum id: UUID) -> Folder? {
        folders.first { $0.albums.contains { $0.id == id } }
    }

    func folder(_ id: UUID) -> Folder? { folders.first { $0.id == id } }

    /// Folders directly inside `parent` (nil = top level), in the order they were made.
    func subfolders(of parent: UUID?) -> [Folder] {
        folders.filter { $0.parentID == parent }
    }

    /// A folder and every folder inside it, at any depth.
    func folderAndDescendants(_ id: UUID) -> [UUID] {
        var result = [id], i = 0
        while i < result.count {
            result += folders.filter { $0.parentID == result[i] }.map(\.id)
            i += 1
        }
        return result
    }

    /// "Weddings ▸ Elise and Jaden" — for menus and pickers.
    func path(ofFolder id: UUID) -> String {
        var names: [String] = [], cur: UUID? = id, guardCount = 0
        while let c = cur, let f = folder(c), guardCount < 64 {
            names.insert(f.name, at: 0); cur = f.parentID; guardCount += 1
        }
        return names.joined(separator: " ▸ ")
    }

    /// Every folder in sidebar order with its depth (for pickers).
    func folderOutline() -> [(folder: Folder, depth: Int)] {
        var out: [(Folder, Int)] = []
        func walk(_ parent: UUID?, _ depth: Int) {
            for f in subfolders(of: parent) { out.append((f, depth)); walk(f.id, depth + 1) }
        }
        walk(nil, 0)
        return out
    }

    func photos(in selection: LibrarySelection) -> [LibraryPhoto] {
        switch selection {
        case .all:
            return photos.sorted { $0.added > $1.added }
        case .edited:
            return photos.filter(\.isEdited).sorted { ($0.editedAt ?? $0.added) > ($1.editedAt ?? $1.added) }
        case .picks:
            return photos.filter { $0.flag == .pick }.sorted { $0.added > $1.added }
        case .rejected:
            return photos.filter { $0.flag == .reject }.sorted { $0.added > $1.added }
        case .needsReview:
            return photos.filter(\.hasDefects).sorted { $0.added > $1.added }
        case .folder(let id):
            guard folder(id) != nil else { return [] }
            let tree = Set(folderAndDescendants(id))
            var seen = Set<UUID>()
            let ids = folders.filter { tree.contains($0.id) }.flatMap { $0.albums.flatMap(\.photoIDs) }
                .filter { seen.insert($0).inserted }
            return ids.compactMap(photo)
        case .album(let id):
            return album(id)?.photoIDs.compactMap(photo) ?? []
        }
    }

    func title(for selection: LibrarySelection) -> String {
        switch selection {
        case .all: return "All Photos"
        case .edited: return "Edited"
        case .picks: return "Picks"
        case .rejected: return "Rejected"
        case .needsReview: return "Needs Review"
        case .folder(let id): return folders.first { $0.id == id }?.name ?? "Folder"
        case .album(let id): return album(id)?.name ?? "Album"
        }
    }

    /// The current collection with the Pick/Reject filter applied — what the grid and filmstrip show.
    func visiblePhotos() -> [LibraryPhoto] {
        photos(in: selection).filter { flagFilter.includes($0.flag) }
    }

    func setIssues(_ issues: [UUID: [PhotoIssue]]) {
        for i in photos.indices {
            if let list = issues[photos[i].id] { photos[i].issues = list.isEmpty ? nil : list.map(\.rawValue) }
        }
        setNeedsSave()
    }

    func clearIssues(_ ids: [UUID]) {
        for i in photos.indices where ids.contains(photos[i].id) { photos[i].issues = nil }
        setNeedsSave()
    }

    func setFlag(_ flag: PhotoFlag?, for ids: [UUID]) {
        var changed = false
        for i in photos.indices where ids.contains(photos[i].id) && photos[i].flag != flag {
            photos[i].flag = flag
            changed = true
        }
        if changed { setNeedsSave() }
    }

    /// The file for a photo, following it if it was moved or renamed in Finder.
    func url(for photo: LibraryPhoto) -> URL? {
        let direct = URL(fileURLWithPath: photo.path)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        guard let bookmark = photo.bookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        if let i = photos.firstIndex(where: { $0.id == photo.id }) {
            photos[i].path = url.path
            if stale { photos[i].bookmark = try? url.bookmarkData() }
            setNeedsSave()
        }
        return url
    }

    // MARK: Importing

    static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .rawImage)
    }

    /// Adds photos (and any photos inside dropped folders). Returns their IDs in order; already-imported
    /// files are reused rather than duplicated.
    @discardableResult
    func importPhotos(_ urls: [URL], intoAlbum albumID: UUID? = nil) -> [UUID] {
        var files: [URL] = []
        for url in urls.map(DropHandler.resolve) {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil,
                                                           options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while files.count < 5000, let item = items?.nextObject() as? URL {
                    if Self.isImage(item) { files.append(item) }
                }
            } else if Self.isImage(url) {
                files.append(url)
            }
        }
        var ids: [UUID] = []
        for file in files.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            if let existing = photos.first(where: { $0.path == file.path }) {
                ids.append(existing.id)
            } else {
                let photo = LibraryPhoto(path: file.path, bookmark: try? file.bookmarkData())
                photos.append(photo)
                ids.append(photo.id)
            }
        }
        if let albumID { add(ids, toAlbum: albumID) }
        setNeedsSave()
        return ids
    }

    func presentImportPanel(intoAlbum albumID: UUID?) -> [UUID] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .rawImage, .folder]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Choose photos (or folders of photos) to add to your library"
        panel.prompt = "Import"
        guard panel.runModal() == .OK else { return [] }
        return importPhotos(panel.urls, intoAlbum: albumID)
    }

    // MARK: Edits

    func saveEdits(_ state: EditState, for id: UUID) {
        guard let i = photos.firstIndex(where: { $0.id == id }) else { return }
        let new: EditState? = state.isIdentity ? nil : state
        guard photos[i].edits != new else { return }
        photos[i].edits = new
        photos[i].editedAt = Date()
        setNeedsSave()
    }

    // MARK: Folders & albums

    @discardableResult
    func createFolder(named name: String = "New Folder", inFolder parent: UUID? = nil) -> UUID {
        let parent = parent.flatMap { folder($0) != nil ? $0 : nil }
        var f = Folder(name: uniqueName(name, existing: subfolders(of: parent).map(\.name)))
        f.parentID = parent
        folders.append(f)
        if let parent, let pi = folders.firstIndex(where: { $0.id == parent }) { folders[pi].expanded = true }
        setNeedsSave()
        return f.id
    }

    /// Creates an album inside a folder (a folder is created if none is given).
    @discardableResult
    func createAlbum(named name: String = "New Album", inFolder folderID: UUID?, photoIDs: [UUID] = []) -> UUID {
        let fid = folderID ?? folders.first?.id ?? createFolder(named: "My Albums")
        guard let fi = folders.firstIndex(where: { $0.id == fid }) else { return UUID() }
        let album = Album(name: uniqueName(name, existing: folders[fi].albums.map(\.name)), photoIDs: photoIDs)
        folders[fi].albums.append(album)
        folders[fi].expanded = true
        setNeedsSave()
        return album.id
    }

    func rename(folder id: UUID, to name: String) {
        guard let i = folders.firstIndex(where: { $0.id == id }), !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        folders[i].name = name
        setNeedsSave()
    }

    func rename(album id: UUID, to name: String) {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        for fi in folders.indices {
            if let ai = folders[fi].albums.firstIndex(where: { $0.id == id }) {
                folders[fi].albums[ai].name = name
                setNeedsSave()
                return
            }
        }
    }

    func setExpanded(_ id: UUID, _ expanded: Bool) {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[i].expanded = expanded
        setNeedsSave()
    }

    /// Deleting a folder (with the folders and albums inside it) or an album never deletes photos —
    /// they stay in All Photos.
    func delete(folder id: UUID) {
        let tree = Set(folderAndDescendants(id))
        folders.removeAll { tree.contains($0.id) }
        if case .folder(let s) = selection, tree.contains(s) { selection = .all }
        if case .album(let a) = selection, album(a) == nil { selection = .all }
        setNeedsSave()
    }

    func delete(album id: UUID) {
        for fi in folders.indices { folders[fi].albums.removeAll { $0.id == id } }
        if case .album(let s) = selection, s == id { selection = .all }
        setNeedsSave()
    }

    /// Can `id` be moved into `parent`? (Not into itself or a folder inside it.)
    func canMove(folder id: UUID, into parent: UUID?) -> Bool {
        guard let parent else { return true }
        return !folderAndDescendants(id).contains(parent)
    }

    /// Moves a folder (with everything in it) inside another folder, or to the top level.
    func moveFolder(_ id: UUID, into parent: UUID?) {
        guard let i = folders.firstIndex(where: { $0.id == id }), canMove(folder: id, into: parent),
              folders[i].parentID != parent else { return }
        folders[i].name = uniqueName(folders[i].name, existing: subfolders(of: parent).map(\.name))
        folders[i].parentID = parent
        if let parent, let pi = folders.firstIndex(where: { $0.id == parent }) { folders[pi].expanded = true }
        setNeedsSave()
    }

    func moveAlbum(_ id: UUID, toFolder folderID: UUID) {
        guard let album = album(id), let target = folders.firstIndex(where: { $0.id == folderID }),
              !folders[target].albums.contains(where: { $0.id == id }) else { return }
        for fi in folders.indices { folders[fi].albums.removeAll { $0.id == id } }
        folders[target].albums.append(album)
        setNeedsSave()
    }

    func add(_ photoIDs: [UUID], toAlbum albumID: UUID) {
        for fi in folders.indices {
            if let ai = folders[fi].albums.firstIndex(where: { $0.id == albumID }) {
                for id in photoIDs where !folders[fi].albums[ai].photoIDs.contains(id) {
                    folders[fi].albums[ai].photoIDs.append(id)
                }
                setNeedsSave()
                return
            }
        }
    }

    func remove(_ photoIDs: [UUID], fromAlbum albumID: UUID) {
        for fi in folders.indices {
            if let ai = folders[fi].albums.firstIndex(where: { $0.id == albumID }) {
                folders[fi].albums[ai].photoIDs.removeAll { photoIDs.contains($0) }
                setNeedsSave()
                return
            }
        }
    }

    /// The folder whose albums act as sorting categories right now (the folder being viewed, or the
    /// folder of the album being viewed) — e.g. a wedding folder with an album per category.
    var sortingFolder: Folder? {
        switch selection {
        case .folder(let id): return folders.first { $0.id == id }
        case .album(let id): return folder(containingAlbum: id)
        default: return nil
        }
    }

    /// Moves photos into a category album: they leave the album being viewed (or every album of the
    /// folder being viewed) so each photo ends up in exactly one category.
    func sort(_ ids: [UUID], into albumID: UUID) {
        if case .album(let current) = selection, current != albumID, album(current)?.holdsEverything != true,
           folder(containingAlbum: current)?.id != folder(containingAlbum: albumID)?.id {
            remove(ids, fromAlbum: current)
        }
        // Each photo belongs to one category: take it out of the target's sibling categories.
        if let f = folder(containingAlbum: albumID) {
            for a in f.categoryAlbums where a.id != albumID { remove(ids, fromAlbum: a.id) }
        }
        add(ids, toAlbum: albumID)
    }

    func setHoldsEverything(_ albumID: UUID, _ value: Bool) {
        for fi in folders.indices {
            if let ai = folders[fi].albums.firstIndex(where: { $0.id == albumID }) {
                folders[fi].albums[ai].holdsEverything = value ? true : nil
                setNeedsSave()
                return
            }
        }
    }

    /// Moves photos from one album to another (used by drag and drop).
    func move(_ ids: [UUID], fromAlbum source: UUID, toAlbum target: UUID) {
        guard source != target else { return }
        remove(ids, fromAlbum: source)
        add(ids, toAlbum: target)
    }

    /// Removes photos from the library (and every album). The files on disk are not touched.
    func removeFromLibrary(_ photoIDs: [UUID]) {
        photos.removeAll { photoIDs.contains($0.id) }
        for fi in folders.indices {
            for ai in folders[fi].albums.indices {
                folders[fi].albums[ai].photoIDs.removeAll { photoIDs.contains($0) }
            }
        }
        for id in photoIDs {
            try? FileManager.default.removeItem(at: editedThumbnailURL(id))
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("Thumbnails/Originals/\(id.uuidString).jpg"))
            ThumbnailCache.shared.forget(id)
        }
        setNeedsSave()
    }

    private func uniqueName(_ base: String, existing: [String]) -> String {
        var name = base, n = 2
        while existing.contains(name) { name = "\(base) \(n)"; n += 1 }
        return name
    }

    // MARK: Thumbnails

    func editedThumbnailURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("Thumbnails").appendingPathComponent("\(id.uuidString).jpg")
    }

    /// Stores a thumbnail that shows the photo's edits.
    func storeEditedThumbnail(_ image: CGImage?, for id: UUID) {
        let url = editedThumbnailURL(id)
        if let image {
            if let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
                CGImageDestinationFinalize(dest)
            }
        } else {
            try? FileManager.default.removeItem(at: url)
        }
        ThumbnailCache.shared.forget(id)
        DispatchQueue.main.async {
            self.thumbnailVersion[id, default: 0] += 1
        }
    }
}

/// Finder-style multi-selection shared by the library grid and the Culling Assistant.
enum MultiSelect {
    /// - Click: select just this photo.
    /// - ⌘-click: add or remove this photo, in any order.
    /// - Shift-click: select every photo from the anchor to this one, in order (⌘⇧ adds the range).
    static func click(_ id: UUID, ordered: [UUID], selection: inout Set<UUID>, anchor: inout UUID?,
                      flags: NSEvent.ModifierFlags = NSEvent.modifierFlags) {   // live keyboard state: reliable inside SwiftUI gestures
        let command = flags.contains(.command), shift = flags.contains(.shift)
        if shift {
            let start = anchor.flatMap { a in ordered.firstIndex(of: a) }
                ?? ordered.firstIndex { selection.contains($0) }
            if let start, let end = ordered.firstIndex(of: id) {
                let range = Set(ordered[min(start, end)...max(start, end)])
                selection = command ? selection.union(range) : range
                if anchor == nil { anchor = ordered[start] }
                return
            }
        }
        if command {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = [id]
        }
        anchor = id
    }

    /// Shift-arrow: extend the selection one photo at a time.
    static func extend(_ delta: Int, ordered: [UUID], selection: inout Set<UUID>, anchor: inout UUID?, cursor: inout UUID?) {
        guard !ordered.isEmpty else { return }
        let a = anchor ?? cursor ?? ordered.first { selection.contains($0) } ?? ordered[0]
        let c = cursor ?? a
        guard let ci = ordered.firstIndex(of: c), let ai = ordered.firstIndex(of: a) else { return }
        let ni = min(max(0, ci + delta), ordered.count - 1)
        selection = Set(ordered[min(ai, ni)...max(ai, ni)])
        anchor = a
        cursor = ordered[ni]
    }
}

/// Fast previews straight from a photo file.
enum FastPreview {
    /// Uses the preview the camera already embedded in the file (RAW and camera JPEGs have one) when it's
    /// big enough, and only decodes the full photo when it isn't. Decoding a RAW file fully takes seconds;
    /// reading its embedded preview takes milliseconds.
    static func image(at url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let embedded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
        if let embedded, max(embedded.width, embedded.height) >= min(maxPixelSize, 640) * 7 / 10 {
            return embedded
        }
        // The embedded preview is missing or tiny (e.g. a 160-px EXIF thumbnail): decode, subsampled.
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary) ?? embedded
    }
}

/// Loads small previews for the library grid and filmstrip: a few at a time, newest requests first,
/// cancelled when a photo scrolls out of view, and saved to disk so the next launch is instant.
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "retouchpro.thumbs"
        q.maxConcurrentOperationCount = max(2, min(6, ProcessInfo.processInfo.activeProcessorCount / 2))
        q.qualityOfService = .userInitiated
        return q
    }()
    private let lock = NSLock()
    private var operations: [UUID: Operation] = [:]
    private var waiters: [UUID: [(NSImage?) -> Void]] = [:]
    private let size = 420

    init() {
        cache.countLimit = 3000
    }

    private var diskDirectory: URL {
        Library.shared.directory.appendingPathComponent("Thumbnails/Originals", isDirectory: true)
    }

    func forget(_ id: UUID) {
        cache.removeObject(forKey: id.uuidString as NSString)
    }

    /// Stops loading a thumbnail nobody is looking at any more.
    func cancel(_ id: UUID) {
        lock.lock()
        if let op = operations[id], !op.isExecuting {
            op.cancel()
            operations[id] = nil
            waiters[id] = nil
        }
        lock.unlock()
    }

    func cachedThumbnail(for id: UUID) -> NSImage? {
        cache.object(forKey: id.uuidString as NSString)
    }

    func thumbnail(for photo: LibraryPhoto, completion: @escaping (NSImage?) -> Void) {
        let key = photo.id.uuidString as NSString
        if let hit = cache.object(forKey: key) { completion(hit); return }

        lock.lock()
        if waiters[photo.id] != nil {
            waiters[photo.id]!.append(completion)
            operations[photo.id]?.queuePriority = .veryHigh
            lock.unlock()
            return
        }
        waiters[photo.id] = [completion]
        lock.unlock()

        let library = Library.shared
        let editedURL = library.editedThumbnailURL(photo.id)
        let diskURL = diskDirectory.appendingPathComponent("\(photo.id.uuidString).jpg")
        let fileURL = URL(fileURLWithPath: photo.path)
        let size = self.size
        let dir = diskDirectory

        let op = BlockOperation()
        op.addExecutionBlock { [weak self, weak op] in
            guard let self, op?.isCancelled == false else { return }
            var image: NSImage?
            if photo.isEdited, let edited = NSImage(contentsOf: editedURL) {
                image = edited
            } else if let saved = NSImage(contentsOf: diskURL) {
                image = saved
            } else {
                var url = fileURL
                if !FileManager.default.fileExists(atPath: url.path),
                   let moved = DispatchQueue.main.sync(execute: { library.url(for: photo) }) {
                    url = moved
                }
                if let cg = FastPreview.image(at: url, maxPixelSize: size) {
                    image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    // Save for next time.
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    if let dest = CGImageDestinationCreateWithURL(diskURL as CFURL, "public.jpeg" as CFString, 1, nil) {
                        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
                        CGImageDestinationFinalize(dest)
                    }
                }
            }
            if let image { self.cache.setObject(image, forKey: key) }
            self.lock.lock()
            let callbacks = self.waiters.removeValue(forKey: photo.id) ?? []
            self.operations[photo.id] = nil
            self.lock.unlock()
            DispatchQueue.main.async { callbacks.forEach { $0(image) } }
        }
        // Newest requests are what's on screen now.
        op.queuePriority = .high
        lock.lock()
        for (_, other) in operations where other.queuePriority == .high { other.queuePriority = .normal }
        operations[photo.id] = op
        lock.unlock()
        queue.addOperation(op)
    }
}
