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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first {
            EditorModel.shared.open(url: url)
        }
    }
}

struct EditorCommands: Commands {
    @ObservedObject var model: EditorModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Photo…") { model.presentOpenPanel() }
                .keyboardShortcut("o")
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
