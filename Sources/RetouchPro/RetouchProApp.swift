import AppKit
import SwiftUI

@main
struct RetouchProApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = EditorModel.shared

    var body: some Scene {
        Window("Retouch Pro", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .defaultSize(width: 1400, height: 880)
        .commands {
            EditorCommands(model: model)
            LayerAndPhotoCommands(model: model)
        }

        // Provides "Retouch Pro ▸ Settings…" and ⌘, automatically.
        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        KeyboardShortcuts.install()
        let saved = UserDefaults.standard.string(forKey: SettingsKey.appearance) ?? AppearanceMode.system.rawValue
        (AppearanceMode(rawValue: saved) ?? .system).apply()
        DispatchQueue.global(qos: .utility).async { Updater.shared.cleanUpOldDownloads() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Updater.shared.checkOnLaunchIfNeeded() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        EditorModel.shared.flushEdits()
        Library.shared.saveNow()
        Thread.sleep(forTimeInterval: 0.3)   // let the background save finish
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ application: NSApplication, open urls: [URL]) {
        EditorModel.shared.openFiles(urls)
    }
}

struct EditorCommands: Commands {
    @ObservedObject var model: EditorModel

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { Updater.shared.check(userInitiated: true) }
        }
        CommandGroup(replacing: .newItem) {
            Button("Import Photos…") { model.presentOpenPanel() }
                .keyboardShortcut("o")
            Button("Import into Library…") {
                model.mode = .library
                _ = Library.shared.presentImportPanel(intoAlbum: model.currentAlbumID)
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            Divider()
            Button("New Folder") { model.mode = .library; Library.shared.createFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New Album") {
                model.mode = .library
                let id = Library.shared.createAlbum(inFolder: nil)
                Library.shared.selection = .album(id)
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
            Divider()
            Button("Export…") { NotificationCenter.default.post(name: .showExport, object: nil) }
                .keyboardShortcut("e")
                .disabled(!model.hasImage)
            Button("Export (Photoshop shortcut)") { NotificationCenter.default.post(name: .showExport, object: nil) }
                .keyboardShortcut("w", modifiers: [.command, .option, .shift])
                .disabled(!model.hasImage)
            Button("Close Photo") { model.close() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(!model.hasImage)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { model.undo() }
                .keyboardShortcut("z")
                .disabled(!model.canUndo)
            Button("Redo") { model.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canRedo)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy Settings") { model.copySettings() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(model.batchTargets.isEmpty)
            Button("Paste Settings") { model.pasteSettings(to: model.batchTargets) }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(model.batchTargets.isEmpty || !model.hasSettingsClipboard)
            Button("Save Preset…") { NotificationCenter.default.post(name: .showSavePreset, object: nil) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!model.hasImage)
            Menu("Apply Preset") {
                ForEach(PresetStore.shared.presets) { preset in
                    Button(preset.name) { model.applyPreset(preset, to: model.batchTargets) }
                }
            }
            .disabled(model.batchTargets.isEmpty || PresetStore.shared.presets.isEmpty)
            Button("Export Selected Photos…") {
                NotificationCenter.default.post(name: .showBatchExport, object: model.batchTargets)
            }
            .keyboardShortcut("e", modifiers: [.command, .option])
            .disabled(model.mode != .library || model.batchTargets.isEmpty)
            Divider()
            Button("Auto Enhance") { model.autoEnhance() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(!model.hasImage)
            Button("Reset All Edits") { model.resetAll() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!model.hasImage)
        }
        CommandGroup(before: .sidebar) {
            Button(model.mode == .library ? "Show Editor" : "Show Library") {
                model.mode = model.mode == .library ? .edit : .library
            }
            .keyboardShortcut("l")
            Button("Previous Photo") { model.stepPhoto(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Next Photo") { model.stepPhoto(1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Divider()
        }
        CommandMenu("Image") {
            ForEach(Tool.allCases) { tool in
                Button("\(tool.title)    \(tool.letter)") { model.mode = .edit; model.tool = tool }
                    .disabled(!model.hasImage)
            }
            Button("White Balance Picker    W") { model.tool = .adjust; model.isPickingWhiteBalance = true }
                .disabled(!model.hasImage)
            Divider()
            Button("Rotate Left") { model.rotateLeft() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!model.hasImage)
            Button("Rotate Right") { model.rotateRight() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!model.hasImage)
            Button("Flip Horizontal") { model.flipHorizontal() }
                .disabled(!model.hasImage)
            Button("Flip Vertical") { model.flipVertical() }
                .disabled(!model.hasImage)
        }
        CommandGroup(before: .toolbar) {
            Button("Zoom In") { model.zoomIn() }
                .keyboardShortcut("=")
                .disabled(!model.hasImage)
            Button("Zoom Out") { model.zoomOut() }
                .keyboardShortcut("-")
                .disabled(!model.hasImage)
            Button("Zoom to Fit") { model.zoomToFit() }
                .keyboardShortcut("0")
                .disabled(!model.hasImage)
            Button("Zoom to 100%") { model.zoomToActual(1) }
                .keyboardShortcut("1")
                .disabled(!model.hasImage)
            Button("Zoom to 200%") { model.zoomToActual(2) }
                .keyboardShortcut("2")
                .disabled(!model.hasImage)
            Button(model.showFilmstrip ? "Hide Filmstrip    /" : "Show Filmstrip    /") { model.showFilmstrip.toggle() }
            Divider()
            Button(model.showOriginal ? "Show Edited" : "Show Original") { model.showOriginal.toggle() }
                .keyboardShortcut("\\", modifiers: .command)
                .disabled(!model.hasImage)
            Divider()
        }
    }
}

struct LayerAndPhotoCommands: Commands {
    @ObservedObject var model: EditorModel

    var body: some Commands {
        CommandMenu("Layer") {
            Button("New Adjustment Layer") { model.mode = .edit; model.addLayer(.adjustment) }
                .keyboardShortcut("n", modifiers: [.command, .option, .shift])
                .disabled(!model.hasImage)
            Button("Duplicate Layer") { model.duplicateSelectedLayer() }
                .keyboardShortcut("j")
                .disabled(model.selectedLayer == nil)
            Button("Delete Layer") { model.deleteSelectedLayer() }
                .disabled(model.selectedLayer == nil)
            Divider()
            Button("Bring to Front") { model.moveSelectedLayerToEdge(top: true) }
                .keyboardShortcut("]", modifiers: [.command, .option])
                .disabled(model.selectedLayer == nil)
            Button("Bring Forward") { model.moveSelectedLayer(up: true) }
                .disabled(model.selectedLayer == nil)
            Button("Send Backward") { model.moveSelectedLayer(up: false) }
                .disabled(model.selectedLayer == nil)
            Button("Send to Back") { model.moveSelectedLayerToEdge(top: false) }
                .keyboardShortcut("[", modifiers: [.command, .option])
                .disabled(model.selectedLayer == nil)
            Divider()
            Button("Invert Mask") { model.invertSelectedMask() }
                .keyboardShortcut("i")
                .disabled(model.selectedLayer == nil)
            Button(model.showMaskOverlay ? "Hide Mask Overlay    O" : "Show Mask Overlay    O") { model.showMaskOverlay.toggle() }
                .disabled(model.selectedLayer == nil)
            Menu("Select Automatically") {
                ForEach(MaskMode.automatic) { mode in
                    Button(mode.rawValue) { model.mode = .edit; model.addLayer(.auto(mode)) }
                }
            }
            .disabled(!model.hasImage)
            Divider()
            Button("Deselect Layer") { model.selectedLayerID = nil; Library.shared.gridSelection = [] }
                .keyboardShortcut("d")
        }
        CommandMenu("Photo") {
            Button("Culling Assistant…") { model.mode = .library; NotificationCenter.default.post(name: .showCulling, object: nil) }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Divider()
            Button("Pick    P") { model.flag(.pick) }
            Button("Reject    X") { model.flag(.reject) }
            Button("Unflag    U") { model.flag(nil) }
            Divider()
            Button("Previous Photo    ←") { model.stepPhoto(-1, inLibraryGrid: model.mode == .library) }
            Button("Next Photo    →") { model.stepPhoto(1, inLibraryGrid: model.mode == .library) }
            Divider()
            Button("Select All Photos") { Library.shared.gridSelection = Set(Library.shared.visiblePhotos().map(\.id)) }
                .disabled(model.mode != .library)
            Button("Save Edits Now") { model.flushEdits(); Library.shared.saveNow() }
                .keyboardShortcut("s")
                .disabled(!model.hasImage)
        }
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { NotificationCenter.default.post(name: .showShortcuts, object: nil) }
                .keyboardShortcut("k", modifiers: [.command, .option, .shift])
        }
        CommandGroup(after: .appSettings) {
            Button("Settings (⌘K)") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
                .keyboardShortcut("k")
        }
    }
}

extension Notification.Name {
    static let showExport = Notification.Name("RetouchPro.showExport")
    static let showShortcuts = Notification.Name("RetouchPro.showShortcuts")
    static let showCulling = Notification.Name("RetouchPro.showCulling")
    static let showSavePreset = Notification.Name("RetouchPro.showSavePreset")
    static let showBatchExport = Notification.Name("RetouchPro.showBatchExport")
}
