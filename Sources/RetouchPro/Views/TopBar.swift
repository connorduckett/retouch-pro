import SwiftUI

struct TopBar: View {
    @EnvironmentObject var model: EditorModel
    @Binding var showExport: Bool

    var body: some View {
        HStack(spacing: 6) {
            Button {
                model.presentOpenPanel()
            } label: {
                Label("Open", systemImage: "folder")
            }
            .buttonStyle(RPButtonStyle())
            .help("Open a photo (⌘O)")

            Divider().frame(height: 18).padding(.horizontal, 4)

            IconButton(systemName: "arrow.uturn.backward", help: "Undo (⌘Z)", disabled: !model.canUndo) { model.undo() }
            IconButton(systemName: "arrow.uturn.forward", help: "Redo (⇧⌘Z)", disabled: !model.canRedo) { model.redo() }

            Spacer(minLength: 12)

            if model.hasImage {
                VStack(spacing: 1) {
                    Text(model.fileName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.rpInk)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(.rpSlate)
                }
            }

            Spacer(minLength: 12)

            if model.hasImage {
                CompareButton()

                HStack(spacing: 0) {
                    IconButton(systemName: "minus.magnifyingglass", help: "Zoom out (⌘−)", disabled: model.zoom <= 1) { model.zoomOut() }
                    Button {
                        model.zoomToFit()
                    } label: {
                        Text(model.zoom <= 1.001 ? "Fit" : "\(Int((model.zoom * 100).rounded()))%")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundColor(.rpCharcoal)
                            .frame(width: 44)
                    }
                    .buttonStyle(.plain)
                    .help("Zoom to fit (⌘0)")
                    IconButton(systemName: "plus.magnifyingglass", help: "Zoom in (⌘+)") { model.zoomIn() }
                }
                .padding(.horizontal, 2)
                .background(RoundedRectangle(cornerRadius: 7).stroke(Color.rpSilver))

                Button {
                    model.autoEnhance()
                } label: {
                    Label("Auto", systemImage: "wand.and.stars")
                }
                .buttonStyle(RPButtonStyle())
                .help("Let Retouch Pro balance exposure and color (⇧⌘A)")

                Button {
                    model.resetAll()
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(RPButtonStyle())
                .disabled(model.state.isIdentity)
                .help("Remove all edits (⇧⌘R)")

                Button {
                    showExport = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(RPButtonStyle(kind: .primary))
                .help("Save a copy of your edited photo (⌘E)")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(Color.rpPaper)
    }

    private var subtitle: String {
        let s = model.outputSize
        var parts = ["\(Int(s.width)) × \(Int(s.height))"]
        if model.isRaw { parts.append("RAW") }
        if model.hasUnexportedChanges { parts.append("Edited") }
        return parts.joined(separator: "  ·  ")
    }
}

/// Press and hold to see the original photo.
struct CompareButton: View {
    @EnvironmentObject var model: EditorModel
    @State private var pressing = false

    var body: some View {
        Label(model.showOriginal ? "Original" : "Before / After", systemImage: "square.split.2x1")
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundColor(model.showOriginal ? .white : .rpInk)
            .background(RoundedRectangle(cornerRadius: 7).fill(model.showOriginal ? Color.rpAccent : Color.rpCard))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.rpSilver))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !pressing { pressing = true; model.showOriginal = true }
                    }
                    .onEnded { _ in
                        pressing = false; model.showOriginal = false
                    }
            )
            .help("Press and hold to compare with the original (or press ⌘\\ to toggle)")
    }
}
