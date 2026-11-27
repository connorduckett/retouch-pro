import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Photo library: All Photos, Edited, and folders containing albums, with a thumbnail grid.
struct LibraryView: View {
    @EnvironmentObject var model: EditorModel
    @ObservedObject private var library = Library.shared

    var body: some View {
        HStack(spacing: 0) {
            LibrarySidebar()
                .frame(width: 240)
            Rectangle().fill(Color.rpMist).frame(width: 1)
            PhotoGrid()
        }
        .background(Color.rpPaper)
    }
}

// MARK: - Sidebar

private struct LibrarySidebar: View {
    @EnvironmentObject var model: EditorModel
    @ObservedObject private var library = Library.shared
    @State private var renaming: UUID?
    @State private var draft = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                sectionHeader("Library")
                row(.all, icon: "photo.on.rectangle", title: "All Photos", count: library.photos.count)
                row(.edited, icon: "slider.horizontal.3", title: "Edited", count: library.photos.filter(\.isEdited).count)
                row(.picks, icon: "flag.fill", title: "Picks", count: library.photos.filter { $0.flag == .pick }.count)
                row(.rejected, icon: "xmark.circle", title: "Rejected", count: library.photos.filter { $0.flag == .reject }.count)
                row(.needsReview, icon: "exclamationmark.triangle", title: "Needs Review", count: library.photos.filter(\.hasDefects).count)

                Button {
                    NotificationCenter.default.post(name: .showCulling, object: nil)
                } label: {
                    Label("Cull a Shoot…", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(RPButtonStyle(kind: .primary))
                .padding(.horizontal, 6)
                .padding(.top, 10)
                .help("Let Retouch Pro sort a shoot into categories and find closed eyes, talking, blur and duplicates (⇧⌘K)")

                HStack {
                    sectionHeader("Folders")
                    Spacer()
                    Menu {
                        Button("New Folder") { startRename(library.createFolder()) }
                        Button("New Album") { newAlbum(in: selectedFolderID) }
                            .disabled(library.folders.isEmpty)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.rpCharcoal)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("New folder or album")
                    .padding(.trailing, 10)
                    .padding(.top, 14)
                }

                if library.folders.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Organize photos into folders, with albums inside — for example a “Weddings” folder with an album for each couple.")
                            .font(.system(size: 11))
                            .foregroundColor(.rpSlate)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            startRename(library.createFolder())
                        } label: {
                            Label("New Folder", systemImage: "folder.badge.plus")
                        }
                        .buttonStyle(RPButtonStyle())
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                }

                ForEach(library.folders) { folder in
                    folderRow(folder)
                    if folder.expanded {
                        ForEach(folder.albums) { album in
                            albumRow(album, in: folder)
                        }
                        Button {
                            newAlbum(in: folder.id)
                        } label: {
                            Label("New Album", systemImage: "plus")
                                .font(.system(size: 11))
                                .foregroundColor(.rpSlate)
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 40)
                        .padding(.vertical, 3)
                    }
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 8)
        }
        .background(Color.rpPaper)
    }

    private var selectedFolderID: UUID? {
        switch library.selection {
        case .folder(let id): return id
        case .album(let id): return library.folder(containingAlbum: id)?.id
        default: return library.folders.last?.id
        }
    }

    private func newAlbum(in folderID: UUID?) {
        let id = library.createAlbum(inFolder: folderID)
        library.selection = .album(id)
        startRename(id)
    }

    private func startRename(_ id: UUID) {
        draft = library.folders.first { $0.id == id }?.name ?? library.album(id)?.name ?? ""
        renaming = id
    }

    private func finishRename(_ id: UUID, folder: Bool) {
        if folder { library.rename(folder: id, to: draft) } else { library.rename(album: id, to: draft) }
        renaming = nil
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.6)
            .foregroundColor(.rpSlate)
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }

    private func row(_ selection: LibrarySelection, icon: String, title: String, count: Int) -> some View {
        let selected = library.selection == selection
        return HStack(spacing: 8) {
            Image(systemName: icon).frame(width: 18)
            Text(title).lineLimit(1)
            Spacer()
            Text("\(count)").font(.system(size: 11).monospacedDigit()).opacity(0.7)
        }
        .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
        .foregroundColor(selected ? .white : .rpInk)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.rpAccent : .clear))
        .contentShape(Rectangle())
        .onTapGesture { library.selection = selection }
    }

    private func folderRow(_ folder: Folder) -> some View {
        let selected = library.selection == .folder(folder.id)
        return HStack(spacing: 6) {
            Button {
                library.setExpanded(folder.id, !folder.expanded)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(folder.expanded ? 90 : 0))
                    .frame(width: 12)
            }
            .buttonStyle(.plain)
            Image(systemName: folder.expanded ? "folder.fill" : "folder").frame(width: 18)
            if renaming == folder.id {
                TextField("Folder name", text: $draft, onCommit: { finishRename(folder.id, folder: true) })
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            } else {
                Text(folder.name).lineLimit(1)
            }
            Spacer()
            Text("\(folder.albums.count)").font(.system(size: 11).monospacedDigit()).opacity(0.7)
        }
        .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
        .foregroundColor(selected ? .white : .rpInk)
        .padding(.horizontal, 6)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.rpAccent : .clear))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { startRename(folder.id) }
        .onTapGesture { library.selection = .folder(folder.id) }
        .contextMenu {
            Button("New Album in “\(folder.name)”") { newAlbum(in: folder.id) }
            Button("Rename…") { startRename(folder.id) }
            Divider()
            Button("Delete Folder") { confirmDelete(folder: folder) }
        }
    }

    private func albumRow(_ album: Album, in folder: Folder) -> some View {
        let selected = library.selection == .album(album.id)
        return AlbumDropRow(album: album) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.stack").frame(width: 18)
                if renaming == album.id {
                    TextField("Album name", text: $draft, onCommit: { finishRename(album.id, folder: false) })
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                } else {
                    Text(album.name).lineLimit(1)
                }
                Spacer()
                if library.sortingFolder?.id == folder.id, let n = folder.albums.firstIndex(where: { $0.id == album.id }), n < 9 {
                    Text("\(n + 1)")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .foregroundColor(selected ? .rpAccent : .rpCharcoal)
                        .frame(width: 15, height: 15)
                        .background(RoundedRectangle(cornerRadius: 3).fill(selected ? Color.white : Color.rpMist))
                        .help("Press \(n + 1) to move selected photos here")
                }
                Text("\(album.photoIDs.count)").font(.system(size: 11).monospacedDigit()).opacity(0.7)
            }
            .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
            .foregroundColor(selected ? .white : .rpInk)
            .padding(.leading, 30)
            .padding(.trailing, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.rpAccent : .clear))
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { startRename(album.id) }
        .onTapGesture { library.selection = .album(album.id) }
        .contextMenu {
            Button("Rename…") { startRename(album.id) }
            Menu("Move to Folder") {
                ForEach(library.folders.filter { $0.id != folder.id }) { f in
                    Button(f.name) { library.moveAlbum(album.id, toFolder: f.id) }
                }
            }
            Divider()
            Button("Delete Album") { confirmDelete(album: album) }
        }
    }

    private func confirmDelete(folder: Folder) {
        let alert = NSAlert()
        alert.messageText = "Delete the folder “\(folder.name)”?"
        alert.informativeText = "Its \(folder.albums.count) album\(folder.albums.count == 1 ? "" : "s") will be deleted too. Your photos stay in All Photos, and nothing is removed from your Mac."
        alert.addButton(withTitle: "Delete Folder")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { library.delete(folder: folder.id) }
    }

    private func confirmDelete(album: Album) {
        let alert = NSAlert()
        alert.messageText = "Delete the album “\(album.name)”?"
        alert.informativeText = "The photos stay in All Photos, and nothing is removed from your Mac."
        alert.addButton(withTitle: "Delete Album")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { library.delete(album: album.id) }
    }
}

/// An album row that accepts photos dragged from the grid (or files from Finder).
private struct AlbumDropRow<Content: View>: View {
    let album: Album
    @ViewBuilder var content: Content
    @State private var targeted = false

    var body: some View {
        content
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.rpAccent, lineWidth: targeted ? 2 : 0))
            .onDrop(of: [.plainText, .fileURL, .image], isTargeted: $targeted) { providers in
                if let p = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) {
                    // Dragging from one album to another moves the photos; hold ⌥ to add a copy instead.
                    let copy = NSEvent.modifierFlags.contains(.option)
                    _ = p.loadObject(ofClass: NSString.self) { obj, _ in
                        guard let text = obj as? String else { return }
                        let (ids, source) = PhotoDrag.decode(text)
                        DispatchQueue.main.async {
                            if let source, !copy { Library.shared.move(ids, fromAlbum: source, toAlbum: album.id) }
                            else { Library.shared.add(ids, toAlbum: album.id) }
                        }
                    }
                    return true
                }
                return DropHandler.handleAll(providers) { urls in
                    Library.shared.importPhotos(urls, intoAlbum: album.id)
                }
            }
    }
}

enum PhotoDrag {
    static let prefix = "retouchpro-photos:"
    /// `source` is the album the photos are dragged out of (so a drop can move rather than copy).
    static func encode(_ ids: [UUID], from source: UUID? = nil) -> String {
        prefix + (source?.uuidString ?? "-") + "|" + ids.map(\.uuidString).joined(separator: ",")
    }
    static func decode(_ text: String) -> (ids: [UUID], source: UUID?) {
        guard text.hasPrefix(prefix) else { return ([], nil) }
        let body = text.dropFirst(prefix.count)
        let parts = body.split(separator: "|", maxSplits: 1).map(String.init)
        let list = parts.count == 2 ? parts[1] : parts[0]
        let source = parts.count == 2 ? UUID(uuidString: parts[0]) : nil
        return (list.split(separator: ",").compactMap { UUID(uuidString: String($0)) }, source)
    }
}

// MARK: - Grid

private struct PhotoGrid: View {
    @EnvironmentObject var model: EditorModel
    @ObservedObject private var library = Library.shared
    private var selected: Set<UUID> {
        get { library.gridSelection }
        nonmutating set { library.gridSelection = newValue }
    }
    @State private var thumbSize: Double = 170
    @State private var dropTargeted = false

    var body: some View {
        let photos = library.visiblePhotos()
        VStack(spacing: 0) {
            toolbar(photos)
            Rectangle().fill(Color.rpMist).frame(height: 1)
            ZStack {
                Color.rpMist
                if photos.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbSize, maximum: thumbSize * 1.4), spacing: 12)],
                                  spacing: 12) {
                            ForEach(photos) { photo in
                                PhotoCell(photo: photo, selected: selected.contains(photo.id),
                                          current: photo.id == model.currentPhotoID, size: thumbSize)
                                    // Select instantly on the first click; a double-click also opens the photo.
                                    .onTapGesture { click(photo.id, in: photos) }
                                    .simultaneousGesture(TapGesture(count: 2).onEnded { model.openPhoto(photo.id) })
                                    .onDrag {
                                        let ids = selected.contains(photo.id) ? photos.map(\.id).filter(selected.contains) : [photo.id]
                                        return NSItemProvider(object: PhotoDrag.encode(ids, from: model.currentAlbumID) as NSString)
                                    }
                                    .contextMenu { contextMenu(for: photo, in: photos) }
                            }
                        }
                        .padding(16)
                    }
                    .background(Color.rpMist.onTapGesture { selected = [] })
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 0).stroke(Color.rpAccent, lineWidth: dropTargeted ? 3 : 0))
            .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
                DropHandler.handleAll(providers) { urls in
                    library.importPhotos(urls, intoAlbum: model.currentAlbumID)
                }
            }
        }
    }

    private func toolbar(_ photos: [LibraryPhoto]) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(library.title(for: library.selection))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.rpInk)
                Text(selected.isEmpty ? "\(photos.count) photo\(photos.count == 1 ? "" : "s")"
                                      : "\(selected.count) of \(photos.count) selected")
                    .font(.system(size: 11))
                    .foregroundColor(.rpSlate)
            }
            Spacer()
            Picker("", selection: $library.flagFilter) {
                ForEach(FlagFilter.allCases) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Show only picks, unflagged or rejected photos")
            if !selected.isEmpty {
                HStack(spacing: 2) {
                    IconButton(systemName: "flag.fill", help: "Pick (P)") { model.flag(.pick) }
                    IconButton(systemName: "xmark", help: "Reject (X)") { model.flag(.reject) }
                    IconButton(systemName: "flag.slash", help: "Unflag (U)") { model.flag(nil) }
                }
                Menu {
                    BatchMenuItems(ids: photos.map(\.id).filter(selected.contains))
                } label: {
                    Label("Batch", systemImage: "square.stack.3d.down.right")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Apply a preset, paste settings or export all selected photos")
                if let folder = library.sortingFolder {
                    Menu {
                        moveMenu(photos.map(\.id).filter(selected.contains), folder: folder)
                    } label: {
                        Label("Move to", systemImage: "arrow.right.square")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Move the selected photos into another category album (or press 1–9)")
                }
                Menu {
                    albumMenu(Array(selected))
                } label: {
                    Label("Add to Album", systemImage: "rectangle.stack.badge.plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                if case .album(let albumID) = library.selection {
                    Button {
                        library.remove(Array(selected), fromAlbum: albumID)
                        selected = []
                    } label: {
                        Label("Remove from Album", systemImage: "minus.circle")
                    }
                    .buttonStyle(RPButtonStyle())
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "photo").font(.system(size: 10))
                Slider(value: $thumbSize, in: 110...320).frame(width: 90)
                Image(systemName: "photo").font(.system(size: 14))
            }
            .foregroundColor(.rpSlate)
            .help("Thumbnail size")
            Button {
                NotificationCenter.default.post(name: .showCulling, object: nil)
            } label: {
                Label("Cull", systemImage: "wand.and.stars")
            }
            .buttonStyle(RPButtonStyle())
            .disabled(photos.isEmpty)
            .help("Culling Assistant: sort these photos into categories and find problems (⇧⌘K)")
            Button {
                let ids = library.presentImportPanel(intoAlbum: model.currentAlbumID)
                selected = Set(ids)
            } label: {
                Label("Import Photos", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(RPButtonStyle(kind: .primary))
            .help("Add photos or whole folders (⇧⌘I)")
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
        .background(Color.rpPaper)
    }

    /// Category albums of the current folder, numbered to match the 1–9 shortcuts.
    @ViewBuilder
    private func moveMenu(_ ids: [UUID], folder: Folder) -> some View {
        ForEach(Array(folder.albums.enumerated()), id: \.element.id) { index, album in
            Button(index < 9 ? "\(album.name)    \(index + 1)" : album.name) {
                model.sortPhotos(ids, into: album.id)
            }
            .disabled(library.selection == .album(album.id))
        }
        Divider()
        Button("New Album in “\(folder.name)”…") {
            let id = library.createAlbum(inFolder: folder.id)
            model.sortPhotos(ids, into: id)
            library.selection = .album(id)
        }
    }

    @ViewBuilder
    private func albumMenu(_ ids: [UUID]) -> some View {
        ForEach(library.folders) { folder in
            Menu(folder.name) {
                ForEach(folder.albums) { album in
                    Button(album.name) { library.add(ids, toAlbum: album.id) }
                }
                Divider()
                Button("New Album in “\(folder.name)”…") {
                    let id = library.createAlbum(inFolder: folder.id, photoIDs: ids)
                    library.selection = .album(id)
                }
            }
        }
        if !library.folders.isEmpty { Divider() }
        Button("New Album…") {
            let id = library.createAlbum(inFolder: nil, photoIDs: ids)
            library.selection = .album(id)
        }
    }

    @ViewBuilder
    private func contextMenu(for photo: LibraryPhoto, in photos: [LibraryPhoto]) -> some View {
        let ids = selected.contains(photo.id) ? photos.map(\.id).filter(selected.contains) : [photo.id]
        Button("Edit") { model.openPhoto(photo.id) }
        Menu("Flag") {
            Button("Pick  (P)") { library.setFlag(.pick, for: ids) }
            Button("Reject  (X)") { library.setFlag(.reject, for: ids) }
            Button("Unflag  (U)") { library.setFlag(nil, for: ids) }
        }
        if let folder = library.sortingFolder {
            Menu("Move to") { moveMenu(ids, folder: folder) }
        }
        Menu("Add to Album") { albumMenu(ids) }
        Divider()
        BatchMenuItems(ids: ids)
        Divider()
        if case .album(let albumID) = library.selection {
            Button("Remove from Album") { library.remove(ids, fromAlbum: albumID); selected = [] }
        }
        if ids.contains(where: { library.photo($0)?.issues != nil }) {
            Button("Clear Problem Tags") { library.clearIssues(ids) }
        }
        Divider()
        Button("Show in Finder") {
            let urls = ids.compactMap(library.photo).compactMap(library.url(for:))
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
        Button("Remove from Library…") { confirmRemove(ids) }
    }

    private func confirmRemove(_ ids: [UUID]) {
        let alert = NSAlert()
        alert.messageText = ids.count == 1 ? "Remove this photo from the library?" : "Remove \(ids.count) photos from the library?"
        alert.informativeText = "They’ll be removed from every album and their edits will be forgotten. The original files stay on your Mac."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let current = model.currentPhotoID, ids.contains(current) { model.close() }
        library.removeFromLibrary(ids)
        selected = []
    }

    private func click(_ id: UUID, in photos: [LibraryPhoto]) {
        var sel = library.gridSelection
        var anchor = library.gridAnchor
        MultiSelect.click(id, ordered: photos.map(\.id), selection: &sel, anchor: &anchor)
        library.gridSelection = sel
        library.gridAnchor = anchor
        library.gridCursor = id
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: library.selection == .all ? "photo.stack" : "rectangle.stack")
                .font(.system(size: 42, weight: .light))
                .foregroundColor(.rpCharcoal)
            Text(library.selection == .all && library.flagFilter == .all ? "Your library is empty"
                 : library.flagFilter != .all ? "No \(library.flagFilter.rawValue.lowercased()) photos here" : "No photos here yet")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.rpInk)
            Text(library.selection == .all
                 ? "Drop photos or folders here, or click Import Photos."
                 : "Drag photos here from All Photos or from Finder, or click Import Photos.")
                .font(.system(size: 12))
                .foregroundColor(.rpSlate)
            Button {
                _ = library.presentImportPanel(intoAlbum: model.currentAlbumID)
            } label: {
                Label("Import Photos…", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(RPButtonStyle(kind: .primary))
        }
        .padding(40)
    }
}

struct PhotoCell: View {
    @ObservedObject private var library = Library.shared
    let photo: LibraryPhoto
    let selected: Bool
    var current = false
    var size: Double = 170
    var showName = true
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Color.rpPaper
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(height: size * 0.75)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(selected ? Color.rpAccent : (current ? Color.rpSlate : .clear), lineWidth: selected ? 3 : 2)
                )
                if let flag = photo.flag {
                    Image(systemName: flag == .pick ? "flag.fill" : "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(flag == .pick ? .rpAccent : .white)
                        .padding(4)
                        .background(Circle().fill(flag == .pick ? Color.white : Color.black.opacity(0.75)))
                        .padding(5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .help(flag == .pick ? "Pick" : "Rejected")
                }
                if photo.hasDefects {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.orange)
                        .padding(4)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                        .padding(5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .help(photo.issueList.filter(\.isDefect).map(\.rawValue).joined(separator: ", "))
                }
                if photo.isEdited {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .padding(4)
                        .background(Circle().fill(Color.rpAccent.opacity(0.9)))
                        .padding(5)
                        .help("Edited")
                }
            }
            if showName {
                Text(photo.name)
                    .font(.system(size: 10.5))
                    .foregroundColor(.rpInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .opacity(photo.flag == .reject ? 0.45 : 1)
        .contentShape(Rectangle())
        .onAppear(perform: load)
        .onDisappear { if image == nil { ThumbnailCache.shared.cancel(photo.id) } }
        .onChange(of: library.thumbnailVersion[photo.id]) { _ in load() }
    }

    private func load() {
        if image == nil, let cached = ThumbnailCache.shared.cachedThumbnail(for: photo.id) { image = cached; return }
        ThumbnailCache.shared.thumbnail(for: photo) { image = $0 }
    }
}

// MARK: - Filmstrip (in the editor)

struct Filmstrip: View {
    @EnvironmentObject var model: EditorModel
    @ObservedObject private var library = Library.shared

    var body: some View {
        let photos = library.visiblePhotos()
        if photos.count > 1, model.currentPhotoID != nil {
            VStack(spacing: 0) {
                Rectangle().fill(Color.rpMist).frame(height: 1)
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(library.title(for: library.selection))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.rpInk)
                            .lineLimit(1)
                        if let i = photos.firstIndex(where: { $0.id == model.currentPhotoID }) {
                            Text("\(i + 1) of \(photos.count)")
                                .font(.system(size: 10))
                                .foregroundColor(.rpSlate)
                        }
                    }
                    .frame(width: 90, alignment: .leading)
                    if let id = model.currentPhotoID {
                        let flag = library.photo(id)?.flag
                        VStack(spacing: 4) {
                            IconButton(systemName: flag == .pick ? "flag.fill" : "flag", help: "Pick (P)") {
                                model.flag(flag == .pick ? nil : .pick)
                            }
                            IconButton(systemName: flag == .reject ? "xmark.circle.fill" : "xmark.circle", help: "Reject (X)") {
                                model.flag(flag == .reject ? nil : .reject)
                            }
                        }
                    }
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 6) {
                                ForEach(photos) { photo in
                                    PhotoCell(photo: photo, selected: photo.id == model.currentPhotoID,
                                              size: 80, showName: false)
                                        .frame(width: 80)
                                        .id(photo.id)
                                        .onTapGesture { model.openPhoto(photo.id) }
                                }
                            }
                            .padding(.vertical, 6)
                        }
                        .onAppear { if let id = model.currentPhotoID { proxy.scrollTo(id, anchor: .center) } }
                        .onChange(of: model.currentPhotoID) { id in
                            if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 76)
                .background(Color.rpPaper)
            }
        }
    }
}
