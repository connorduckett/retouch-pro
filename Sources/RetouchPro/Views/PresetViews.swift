import AppKit
import SwiftUI

/// "Save Preset" — name it and choose which settings it carries.
struct PresetSaveSheet: View {
    @EnvironmentObject var model: EditorModel
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var groups = PresetGroup.defaults

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "square.stack.3d.down.right").font(.system(size: 18))
                Text("Save Preset").font(.system(size: 16, weight: .semibold))
            }
            .foregroundColor(.rpInk)
            Text("Saves this photo’s settings so you can apply them to other photos — one at a time or many at once from the Library.")
                .font(.system(size: 11.5)).foregroundColor(.rpSlate)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Preset name (e.g. Warm Golden Hour)", text: $name)
                .textFieldStyle(.roundedBorder)
            VStack(alignment: .leading, spacing: 6) {
                Text("INCLUDE").font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundColor(.rpSlate)
                ForEach(PresetGroup.allCases) { g in
                    Toggle(isOn: Binding(get: { groups.contains(g) },
                                         set: { if $0 { groups.insert(g) } else { groups.remove(g) } })) {
                        Text(label(g)).font(.system(size: 12))
                    }
                }
            }
            Text("Spot healing, layers and masks belong to one photo, so they aren’t included.")
                .font(.system(size: 10.5)).foregroundColor(.rpSlate)
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .buttonStyle(RPButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Save Preset") {
                    PresetStore.shared.add(Preset(name: name.trimmingCharacters(in: .whitespaces), from: model.state, groups: groups))
                    model.batchMessage = "Saved preset “\(name.trimmingCharacters(in: .whitespaces))”."
                    isPresented = false
                }
                .buttonStyle(RPButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || groups.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 420)
        .background(Color.rpPaper)
    }

    private func label(_ g: PresetGroup) -> String {
        switch g {
        case .light: return "Light (exposure, contrast, highlights, shadows, whites, blacks)"
        case .color: return "Color (temperature, tint, vibrance, saturation)"
        case .retouch: return "Retouch (shadows, sun spots, skin spots)"
        case .detail: return "Detail (clarity, sharpen, noise reduction)"
        case .effects: return "Effects (vignette, grain, fade)"
        case .look: return "Look and its strength"
        case .crop: return "Crop, straighten & rotation"
        }
    }
}

/// The user's presets, shown in the Looks panel. Click to apply to the open photo.
struct PresetList: View {
    @EnvironmentObject var model: EditorModel
    @ObservedObject private var store = PresetStore.shared
    @State private var renaming: UUID?
    @State private var draft = ""

    var body: some View {
        SectionCard(title: "Your Presets") {
            if store.presets.isEmpty {
                Text("Set up a photo the way you like, then click Save as Preset to reuse it on other photos.")
                    .font(.system(size: 11)).foregroundColor(.rpSlate)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(store.presets) { preset in
                HStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.down.right").foregroundColor(.rpCharcoal)
                    if renaming == preset.id {
                        TextField("Name", text: $draft, onCommit: {
                            store.rename(preset.id, to: draft); renaming = nil
                        })
                        .textFieldStyle(.roundedBorder)
                    } else {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(preset.name).font(.system(size: 12, weight: .medium)).foregroundColor(.rpInk)
                            Text(preset.summary).font(.system(size: 9.5)).foregroundColor(.rpSlate).lineLimit(1)
                        }
                    }
                    Spacer()
                    Button("Apply") { model.applyPreset(preset, to: model.batchTargets) }
                        .buttonStyle(RPButtonStyle())
                }
                .contentShape(Rectangle())
                .contextMenu {
                    Button("Apply") { model.applyPreset(preset, to: model.batchTargets) }
                    Button("Rename…") { draft = preset.name; renaming = preset.id }
                    Divider()
                    Button("Delete Preset") { store.delete(preset.id) }
                }
            }
            Button {
                NotificationCenter.default.post(name: .showSavePreset, object: nil)
            } label: {
                Label("Save as Preset…", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(RPButtonStyle())
            .disabled(!model.hasImage)
            Text("To apply a preset to many photos, select them in the Library and use Batch ▸ Apply Preset.")
                .font(.system(size: 10.5)).foregroundColor(.rpSlate)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Library "Batch" menu for the selected photos.
struct BatchMenuItems: View {
    @EnvironmentObject var model: EditorModel
    @ObservedObject private var store = PresetStore.shared
    let ids: [UUID]

    var body: some View {
        Menu("Apply Preset") {
            if store.presets.isEmpty {
                Text("No presets yet — save one from the editor")
            }
            ForEach(store.presets) { preset in
                Button(preset.name) { model.applyPreset(preset, to: ids) }
            }
        }
        Button("Copy Settings") {
            Library.shared.gridSelection = Set(ids.prefix(1))
            model.copySettings()
        }
        .disabled(ids.count != 1)
        Button("Paste Settings to \(ids.count) Photo\(ids.count == 1 ? "" : "s")") { model.pasteSettings(to: ids) }
            .disabled(!model.hasSettingsClipboard)
        Button("Reset to Original") { model.resetSettings(of: ids) }
        Divider()
        Button("Export \(ids.count) Photo\(ids.count == 1 ? "" : "s")…") {
            NotificationCenter.default.post(name: .showBatchExport, object: ids)
        }
    }
}

/// Small confirmation banner ("Applied preset to 120 photos").
struct BatchBanner: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        if let message = model.batchMessage {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                Text(message).font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.rpAccent))
            .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .onTapGesture { model.batchMessage = nil }
        }
    }
}
