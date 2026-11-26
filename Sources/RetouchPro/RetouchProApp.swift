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
        .commands { EditorCommands(model: model) }

        // Provides "Retouch Pro ▸ Settings…" and ⌘, automatically.
        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let saved = UserDefaults.standard.string(forKey: SettingsKey.appearance) ?? AppearanceMode.system.rawValue
        (AppearanceMode(rawValue: saved) ?? .system).apply()
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
            Button("Copy Edits") { model.copyEdits() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!model.hasImage)
            Button("Paste Edits") { model.pasteEdits() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(!model.hasImage || !model.hasClipboard)
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
                Button(tool.title) { model.tool = tool }
                    .keyboardShortcut(KeyEquivalent(tool.shortcut), modifiers: .command)
                    .disabled(!model.hasImage)
            }
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
            Divider()
            Button(model.showOriginal ? "Show Edited" : "Show Original") { model.showOriginal.toggle() }
                .keyboardShortcut("\\", modifiers: .command)
                .disabled(!model.hasImage)
            Divider()
        }
    }
}

extension Notification.Name {
    static let showExport = Notification.Name("RetouchPro.showExport")
}
