import AppKit
import SwiftUI

/// Single-key shortcuts (Photoshop / Lightroom style). ⌘ shortcuts live in the menus (RetouchProApp.swift).
/// Keys are ignored while you're typing in a text field or a sheet/window other than the editor is in front.
enum KeyboardShortcuts {
    struct Item: Identifiable {
        let keys: String
        let action: String
        var id: String { keys + action }
    }

    struct Section: Identifiable {
        let title: String
        let items: [Item]
        var id: String { title }
    }

    /// Everything, for the Keyboard Shortcuts window.
    static let reference: [Section] = [
        Section(title: "Tools", items: [
            Item(keys: "E  or  D", action: "Adjust (edit)"),
            Item(keys: "C", action: "Crop & Rotate"),
            Item(keys: "J  or  S", action: "Heal (spot healing / clone)"),
            Item(keys: "V", action: "Layers (move text & shapes)"),
            Item(keys: "W", action: "White balance picker (click something neutral gray)"),
            Item(keys: "T", action: "New text layer"),
            Item(keys: "M", action: "New rectangle shape"),
            Item(keys: "B", action: "Brush mask (hold ⌥ while painting to erase)"),
            Item(keys: "L", action: "New gradient (linear) mask"),
            Item(keys: "R", action: "New radial mask"),
            Item(keys: "A", action: "Show healed spots (in Heal)"),
        ]),
        Section(title: "Masks", items: [
            Item(keys: "O", action: "Show / hide mask overlay"),
            Item(keys: "⇧O", action: "Change mask overlay color"),
            Item(keys: "⌘I", action: "Invert mask"),
            Item(keys: "[  /  ]", action: "Smaller / larger brush"),
        ]),
        Section(title: "Layers", items: [
            Item(keys: "⌘J", action: "Duplicate layer"),
            Item(keys: "⌥⇧⌘N", action: "New adjustment layer"),
            Item(keys: "⌥⌘]  /  ⌥⌘[", action: "Bring layer to front / send to back"),
            Item(keys: "⌥.  /  ⌥,", action: "Select top / bottom layer"),
            Item(keys: "⌘D", action: "Deselect layer"),
            Item(keys: "Delete", action: "Delete selected layer (in Layers)"),
        ]),
        Section(title: "View", items: [
            Item(keys: "\\", action: "Show original (before)"),
            Item(keys: "Space", action: "Toggle Fit / 100% zoom"),
            Item(keys: "⌘+  /  ⌘−", action: "Zoom in / out"),
            Item(keys: "⌘0  /  ⌘1  /  ⌘2", action: "Fit / 100% / 200%"),
            Item(keys: "F", action: "Full screen"),
            Item(keys: "/", action: "Show / hide filmstrip"),
            Item(keys: "G", action: "Library grid"),
            Item(keys: "⌘L", action: "Switch Library / Editor"),
        ]),
        Section(title: "Photos", items: [
            Item(keys: "P", action: "Pick (flag)"),
            Item(keys: "X", action: "Reject"),
            Item(keys: "U", action: "Unflag"),
            Item(keys: "←  /  →", action: "Previous / next photo"),
            Item(keys: "1 – 9", action: "Move photo(s) to that category album"),
            Item(keys: "Delete", action: "Remove photo (in Library)"),
            Item(keys: "⌘A  /  ⌘D", action: "Select all / none (in Library)"),
            Item(keys: "⌘-click", action: "Add or remove one photo from the selection"),
            Item(keys: "Shift-click  /  ⇧←→", action: "Select a run of photos in order"),
            Item(keys: "⌘O  /  ⇧⌘I", action: "Import photos"),
            Item(keys: "⇧⌘K", action: "Culling Assistant"),
            Item(keys: "⇧⌘N  /  ⌥⌘N", action: "New folder / album"),
        ]),
        Section(title: "Editing", items: [
            Item(keys: "⇧A", action: "Auto Enhance (auto tone)"),
            Item(keys: "⌘Z  /  ⇧⌘Z", action: "Undo / redo"),
            Item(keys: "⇧⌘C  /  ⇧⌘V", action: "Copy settings / paste onto all selected photos"),
            Item(keys: "⇧⌘P", action: "Save settings as a preset"),
            Item(keys: "⌥⌘E", action: "Export all selected photos"),
            Item(keys: "⌘[  /  ⌘]", action: "Rotate left / right"),
            Item(keys: "⇧⌘R", action: "Reset all edits"),
            Item(keys: "⌘S", action: "Save edits now (they also save automatically)"),
            Item(keys: "⌘E  /  ⇧E", action: "Export"),
            Item(keys: "⌘,  or  ⌘K", action: "Settings"),
            Item(keys: "⌥⇧⌘K", action: "This list"),
        ]),
    ]

    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event) ? nil : event
        }
    }

    /// Returns true if the key was used.
    private static func handle(_ event: NSEvent) -> Bool {
        guard let window = NSApp.keyWindow ?? event.window, window.attachedSheet == nil, !window.isSheet,
              !window.title.contains("Settings"), window.styleMask.contains(.titled) else { return false }
        // Never steal keys from text fields or the font/name editors.
        if window.firstResponder is NSText || window.firstResponder is NSTextField { return false }

        let model = EditorModel.shared
        let library = Library.shared
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = (event.charactersIgnoringModifiers ?? "").lowercased()

        // Option-only combinations.
        if flags == [.option] {
            switch event.keyCode {
            case 47: model.selectLayerEdge(top: true); return true    // ⌥.
            case 43: model.selectLayerEdge(top: false); return true   // ⌥,
            default: return false
            }
        }

        // Arrow keys and Delete (no modifiers).
        if flags.isEmpty {
            switch event.keyCode {
            case 123: model.stepPhoto(-1, inLibraryGrid: model.mode == .library); return true   // ←
            case 124: model.stepPhoto(1, inLibraryGrid: model.mode == .library); return true    // →
            case 51, 117:                                                                       // Delete / Forward Delete
                if model.mode == .library { model.removeSelectedPhotos(); return true }
                if model.tool == .layers, model.selectedLayer != nil { model.deleteSelectedLayer(); return true }
                return false
            case 49:                                                                            // Space
                guard model.mode == .edit, model.hasImage else { return false }
                model.toggleZoomState()
                return true
            default: break
            }
        }

        if flags == [.shift] && model.mode == .library {
            switch event.keyCode {
            case 123: model.stepPhoto(-1, inLibraryGrid: true, extend: true); return true
            case 124: model.stepPhoto(1, inLibraryGrid: true, extend: true); return true
            default: break
            }
        }
        if flags == [.command] && model.mode == .library && key == "a" {
            library.gridSelection = Set(library.visiblePhotos().map(\.id))
            return true
        }

        if flags == [.shift] {
            switch key {
            case "a": guard model.hasImage else { return false }; model.autoEnhance(); return true
            case "o": model.maskOverlayColorIndex += 1; model.showMaskOverlay = true; return true
            case "e": guard model.hasImage else { return false }
                NotificationCenter.default.post(name: .showExport, object: nil); return true
            default: return false
            }
        }

        guard flags.isEmpty else { return false }

        // 1–9 sort into the current folder's category albums (library and editor).
        if let n = Int(key), (1...9).contains(n) {
            return model.sortSelected(intoAlbumNumber: n)
        }

        // Flags work in both the library and the editor.
        switch key {
        case "p": model.flag(.pick); return true
        case "x": model.flag(.reject); return true
        case "u": model.flag(nil); return true
        case "g": model.mode = .library; return true
        case "f": window.toggleFullScreen(nil); return true
        default: break
        }

        if model.mode == .library {
            if key == "e" || key == "d", let id = library.gridSelection.first ?? model.currentPhotoID {
                model.openPhoto(id)
                return true
            }
            return false
        }

        guard model.hasImage else { return false }
        switch key {
        case "e", "d": model.tool = .adjust
        case "c": model.tool = .crop
        case "j", "s": model.tool = .heal
        case "v": model.tool = .layers
        case "w": model.tool = .adjust; model.isPickingWhiteBalance.toggle()
        case "t": model.addLayer(.text)
        case "m": model.addLayer(.shape(.rectangle))
        case "b": model.startBrushMask()
        case "l": model.addMaskLayer(.linear)
        case "r": model.addMaskLayer(.radial)
        case "o": model.showMaskOverlay.toggle()
        case "a":
            guard model.tool == .heal else { return false }
            let d = UserDefaults.standard
            d.set(!d.bool(forKey: SettingsKey.showHealMarkers), forKey: SettingsKey.showHealMarkers)
        case "\\": model.showOriginal.toggle()
        case "/": model.showFilmstrip.toggle()
        case "[": model.resizeBrush(smaller: true)
        case "]": model.resizeBrush(smaller: false)
        default: return false
        }
        return true
    }
}

struct KeyboardShortcutsView: View {
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "keyboard")
                Text("Keyboard Shortcuts").font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("Done") { isPresented = false }
                    .buttonStyle(RPButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
            }
            .foregroundColor(.rpInk)
            .padding(18)
            Rectangle().fill(Color.rpMist).frame(height: 1)
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .top), GridItem(.flexible(), alignment: .top)],
                          alignment: .leading, spacing: 18) {
                    ForEach(KeyboardShortcuts.reference) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.title.uppercased())
                                .font(.system(size: 10.5, weight: .semibold))
                                .tracking(0.6)
                                .foregroundColor(.rpSlate)
                            ForEach(section.items) { item in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(item.keys)
                                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                        .foregroundColor(.rpInk)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.rpMist))
                                        .frame(width: 118, alignment: .leading)
                                    Text(item.action)
                                        .font(.system(size: 12))
                                        .foregroundColor(.rpInk)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                .padding(18)
            }
            Text("Single-letter shortcuts don’t fire while you’re typing in a text box.")
                .font(.system(size: 11))
                .foregroundColor(.rpSlate)
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
        }
        .frame(width: 720, height: 600)
        .background(Color.rpCard)
    }
}
