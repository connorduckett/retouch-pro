import AppKit
import SwiftUI

struct LayersPanel: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        VStack(spacing: 12) {
            SectionCard(title: "Layers") {
                HStack(spacing: 6) {
                    AddLayerMenu()
                    Spacer()
                    IconButton(systemName: "arrow.up", help: "Move layer up",
                               disabled: !canMove(up: true)) { model.moveSelectedLayer(up: true) }
                    IconButton(systemName: "arrow.down", help: "Move layer down",
                               disabled: !canMove(up: false)) { model.moveSelectedLayer(up: false) }
                    IconButton(systemName: "plus.square.on.square", help: "Duplicate layer",
                               disabled: model.selectedLayer == nil) { model.duplicateSelectedLayer() }
                    IconButton(systemName: "trash", help: "Delete layer",
                               disabled: model.selectedLayer == nil) { model.deleteSelectedLayer() }
                }

                VStack(spacing: 4) {
                    ForEach(model.state.layers.reversed()) { layer in
                        LayerRow(layer: layer, selected: layer.id == model.selectedLayerID)
                    }
                    BackgroundRow(selected: model.selectedLayerID == nil)
                }
            }

            if let layer = model.selectedLayer {
                LayerProperties(layer: layer)
                    .id(layer.id)
            } else if model.state.layers.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Layers stack on top of your photo.")
                        .font(.system(size: 12, weight: .semibold))
                    Text("• **Adjustment layers** change light and color only where you paint, or through a gradient.\n• **Remove Shadows / Sun Spots** layers fix just the areas you brush.\n• **Text, shapes and pen paths** stay sharp and scale with your crop.")
                        .font(.system(size: 11.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundColor(.rpInk)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.rpCard))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.rpMist))
            }
        }
    }

    private func canMove(up: Bool) -> Bool {
        guard let i = model.selectedLayerIndex else { return false }
        return up ? i < model.state.layers.count - 1 : i > 0
    }
}

struct AddLayerMenu: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        Menu {
            Section("Mask automatically") {
                ForEach(MaskMode.automatic) { mode in
                    Button {
                        model.addLayer(.auto(mode))
                    } label: {
                        Label("Select \(mode.rawValue)", systemImage: mode.icon)
                    }
                }
            }
            Section("Mask by hand") {
                Button {
                    model.addLayer(.adjustment)
                    model.updateSelectedLayer { $0.mask.mode = .brush; $0.name = "Brush Mask" }
                    model.commit()
                } label: { Label("Brush Mask", systemImage: MaskMode.brush.icon) }
                Button {
                    model.addLayer(.adjustment)
                    model.updateSelectedLayer { $0.mask.mode = .linear; $0.name = "Gradient Mask" }
                    model.commit()
                } label: { Label("Gradient Mask", systemImage: MaskMode.linear.icon) }
                Button {
                    model.addLayer(.adjustment)
                    model.updateSelectedLayer { $0.mask.mode = .radial; $0.name = "Radial Mask" }
                    model.commit()
                } label: { Label("Radial Mask", systemImage: MaskMode.radial.icon) }
            }
            Section("Adjust an area") {
                Button("Adjustment Layer") { model.addLayer(.adjustment) }
                Button("Brighten (radial)") { model.addLayer(.brightenFaces) }
            }
            Section("Retouch (paint where needed)") {
                Button("Remove Shadows") { model.addLayer(.removeShadows) }
                Button("Tame Sun Spots") { model.addLayer(.removeSunSpots) }
                Button("Fade Skin Spots") { model.addLayer(.smoothSkinSpots) }
            }
            Section("Graphics") {
                Button("Text") { model.addLayer(.text) }
                Menu("Shape") {
                    ForEach(ShapeKind.allCases) { shape in
                        Button(shape.rawValue) { model.addLayer(.shape(shape)) }
                    }
                }
                Button("Pen Path") { model.addLayer(.path) }
            }
        } label: {
            Label("Add", systemImage: "plus")
                .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.rpAccent))
        .foregroundColor(.white)
        .help("Add a layer")
    }
}

private struct LayerRow: View {
    @EnvironmentObject var model: EditorModel
    let layer: Layer
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button {
                model.toggleVisibility(layer.id)
            } label: {
                Image(systemName: layer.visible ? "eye" : "eye.slash")
                    .font(.system(size: 11))
                    .frame(width: 18)
                    .foregroundColor(selected ? .white : (layer.visible ? .rpCharcoal : .rpSilver))
            }
            .buttonStyle(.plain)
            .help(layer.visible ? "Hide layer" : "Show layer")

            Image(systemName: layer.kind.icon)
                .font(.system(size: 12))
                .frame(width: 18)
            Text(layer.name)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .lineLimit(1)
            Spacer()
            if layer.mask.mode != .none {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.system(size: 10))
                    .help("Has a mask")
            }
        }
        .foregroundColor(selected ? .white : .rpInk)
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.rpAccent : Color.rpPaper))
        .contentShape(Rectangle())
        .onTapGesture { model.selectedLayerID = layer.id }
        .opacity(layer.visible ? 1 : 0.6)
    }
}

private struct BackgroundRow: View {
    @EnvironmentObject var model: EditorModel
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill").font(.system(size: 10)).frame(width: 18)
            Image(systemName: "photo").font(.system(size: 12)).frame(width: 18)
            Text("Photo").font(.system(size: 12))
            Spacer()
        }
        .foregroundColor(.rpSlate)
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 7).stroke(Color.rpMist))
        .contentShape(Rectangle())
        .onTapGesture { model.selectedLayerID = nil }
        .help("Your photo, with the Adjust, Looks, Crop and Heal edits")
    }
}

// MARK: - Properties

private struct LayerProperties: View {
    @EnvironmentObject var model: EditorModel
    let layer: Layer

    private func binding<T>(_ key: WritableKeyPath<Layer, T>) -> Binding<T> {
        Binding(get: { model.selectedLayer?[keyPath: key] ?? layer[keyPath: key] },
                set: { v in model.updateSelectedLayer { $0[keyPath: key] = v } })
    }

    /// For toggles and pickers: change and record an undo step at once.
    private func committing<T>(_ key: WritableKeyPath<Layer, T>) -> Binding<T> {
        Binding(get: { model.selectedLayer?[keyPath: key] ?? layer[keyPath: key] },
                set: { v in model.updateSelectedLayer { $0[keyPath: key] = v }; model.commit() })
    }

    var body: some View {
        VStack(spacing: 12) {
            SectionCard(title: "Layer") {
                TextField("Name", text: binding(\.name), onCommit: { model.commit() })
                    .textFieldStyle(.roundedBorder)
                RPSlider(title: "Opacity", value: binding(\.opacity), range: 0...100, defaultValue: 100,
                         format: { "\(Int($0.rounded()))%" }, onCommit: { model.commit() })
                if layer.isContent {
                    labeled("Blend") {
                        Picker("", selection: committing(\.blend)) {
                            ForEach(LayerBlendMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                    }
                }
            }

            switch layer.kind {
            case .adjustment:
                AdjustmentSliders(
                    adjustments: binding(\.adjustments),
                    onCommit: { model.commit() },
                    onReset: { change in model.updateSelectedLayer { change(&$0.adjustments) }; model.commit() }
                )
            case .text:
                textSection
            case .shape:
                shapeSection
            case .path:
                pathSection
            }

            maskSection
        }
    }

    // MARK: Text

    private static let featuredFonts = [
        "Didot", "Bodoni 72", "Baskerville", "Georgia", "Playfair Display", "Cormorant Garamond",
        "Helvetica Neue", "Avenir Next", "Futura", "Gill Sans", "Montserrat",
        "Snell Roundhand", "Savoye LET", "Zapfino", "Bradley Hand", "Noteworthy", "American Typewriter",
    ]

    private var fontFamilies: [String] {
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        let featured = Self.featuredFonts.filter { installed.contains($0) }
        return featured + installed.subtracting(featured).sorted()
    }

    private var textSection: some View {
        SectionCard(title: "Text") {
            TextEditor(text: binding(\.text))
                .font(.system(size: 13))
                .frame(height: 70)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.rpPaper))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.rpSilver))
                .onChange(of: layer.text) { _ in }
                .onDisappear { model.commit() }

            labeled("Font") {
                Picker("", selection: committing(\.fontFamily)) {
                    ForEach(fontFamilies, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            }
            labeled("Weight") {
                Picker("", selection: committing(\.fontWeight)) {
                    Text("Light").tag(3.0)
                    Text("Regular").tag(5.0)
                    Text("Medium").tag(6.0)
                    Text("Bold").tag(9.0)
                }
                .labelsHidden()
                Toggle("Italic", isOn: committing(\.italic))
            }
            labeled("Align") {
                Picker("", selection: committing(\.alignment)) {
                    ForEach(TextAlign.allCases) { Image(systemName: $0.icon).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            labeled("Color") {
                ColorPicker("", selection: colorBinding(\.textColor), supportsOpacity: true)
                    .labelsHidden()
                Spacer()
            }
            HStack(spacing: 14) {
                Toggle("Drop shadow", isOn: committing(\.textShadow)).fixedSize()
                Toggle("All caps", isOn: committing(\.uppercase)).fixedSize()
                Spacer()
            }
            .font(.system(size: 12))
            RPSlider(title: "Size", value: binding(\.fontSize), range: 1...30, defaultValue: 7,
                     format: { String(format: "%.1f", $0) }, onCommit: { model.commit() })
            Toggle("Shrink to fit the box", isOn: committing(\.autoFit))
                .font(.system(size: 12))
            RPSlider(title: "Letter Spacing", value: binding(\.letterSpacing), range: -10...60, defaultValue: 0,
                     onCommit: { model.commit() })
            RPSlider(title: "Line Spacing", value: binding(\.lineSpacing), range: -30...100, defaultValue: 0,
                     onCommit: { model.commit() })
            Text("Text size is relative to the photo, so it stays in proportion when you crop or export at any size. Drag the box on the photo to move or resize it — the text re-flows to fit.")
                .font(.system(size: 10.5))
                .foregroundColor(.rpSlate)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Shape & path

    private var fillStroke: some View {
        VStack(spacing: 10) {
            labeled("Fill") {
                Toggle("", isOn: committing(\.fillEnabled)).labelsHidden()
                ColorPicker("", selection: colorBinding(\.fillColor), supportsOpacity: true)
                    .labelsHidden()
                    .disabled(!layer.fillEnabled)
                Spacer()
            }
            labeled("Stroke") {
                Toggle("", isOn: committing(\.strokeEnabled)).labelsHidden()
                ColorPicker("", selection: colorBinding(\.strokeColor), supportsOpacity: true)
                    .labelsHidden()
                    .disabled(!layer.strokeEnabled)
                Spacer()
            }
            if layer.strokeEnabled || (layer.kind == .shape && layer.shapeKind == .line) || (layer.kind == .path && !layer.pathClosed) {
                RPSlider(title: "Stroke Width", value: binding(\.strokeWidth), range: 0.1...6, defaultValue: 0.6,
                         format: { String(format: "%.1f", $0) }, onCommit: { model.commit() })
            }
        }
    }

    private var shapeSection: some View {
        SectionCard(title: "Shape") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                ForEach(ShapeKind.allCases) { kind in
                    Button {
                        model.updateSelectedLayer { $0.shapeKind = kind }
                        model.commit()
                    } label: {
                        Image(systemName: kind.icon)
                            .font(.system(size: 14))
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                            .foregroundColor(layer.shapeKind == kind ? .white : .rpCharcoal)
                            .background(RoundedRectangle(cornerRadius: 6).fill(layer.shapeKind == kind ? Color.rpAccent : Color.rpPaper))
                    }
                    .buttonStyle(.plain)
                    .help(kind.rawValue)
                }
            }
            fillStroke
            if layer.shapeKind == .rectangle {
                RPSlider(title: "Corner Radius", value: binding(\.cornerRadius), range: 0...25, defaultValue: 0,
                         format: { String(format: "%.1f", $0) }, onCommit: { model.commit() })
            }
        }
    }

    private var pathSection: some View {
        SectionCard(title: "Pen Path") {
            Toggle("Add points by clicking the photo", isOn: $model.penActive)
                .font(.system(size: 12))
            HStack(spacing: 8) {
                Toggle("Closed", isOn: committing(\.pathClosed))
                Toggle("Smooth curves", isOn: committing(\.pathSmooth))
                Spacer()
            }
            .font(.system(size: 12))
            HStack(spacing: 8) {
                Button("Remove Last Point") {
                    model.updateSelectedLayer { if !$0.pathPoints.isEmpty { $0.pathPoints.removeLast(); $0.pathClosed = false } }
                    model.commit()
                }
                .buttonStyle(RPButtonStyle())
                .disabled(layer.pathPoints.isEmpty)
                Button("Clear") {
                    model.updateSelectedLayer { $0.pathPoints = []; $0.pathClosed = false }
                    model.commit()
                }
                .buttonStyle(RPButtonStyle())
                .disabled(layer.pathPoints.isEmpty)
                Spacer()
            }
            fillStroke
            Text("Click to place points; click the first point to close the shape. Drag any point to reshape. Fill shows once the path is closed.")
                .font(.system(size: 10.5))
                .foregroundColor(.rpSlate)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Mask

    private var maskSection: some View {
        SectionCard(title: "Mask") {
            if layer.isContent {
                Toggle("Edit mask on the photo", isOn: $model.editingMask)
                    .font(.system(size: 12))
            }
            Picker("", selection: Binding(
                get: { layer.mask.mode.isAutomatic ? MaskMode.none : layer.mask.mode },
                set: { mode in model.updateSelectedLayer { $0.mask.mode = mode }; model.commit() })) {
                ForEach(MaskMode.manual) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .opacity(layer.mask.mode.isAutomatic ? 0.55 : 1)

            HStack(spacing: 6) {
                ForEach(MaskMode.automatic) { mode in
                    Button {
                        model.refineAutoMask = false
                        model.applyAutoMask(mode)
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: mode.icon).font(.system(size: 13))
                            Text(mode.rawValue).font(.system(size: 9.5, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .foregroundColor(layer.mask.mode == mode ? .white : .rpCharcoal)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(RoundedRectangle(cornerRadius: 7).fill(layer.mask.mode == mode ? Color.rpAccent : Color.rpPaper))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.rpMist))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Automatically select \(mode.rawValue.lowercased())")
                }
            }
            .disabled(model.isDetecting)

            if model.isDetecting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finding \(layer.mask.mode.isAutomatic ? layer.mask.mode.rawValue.lowercased() : "selection")…")
                        .font(.system(size: 11))
                        .foregroundColor(.rpInk)
                }
            }
            if let message = model.autoMaskMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            switch layer.mask.mode {
            case .none:
                Text(layer.isContent ? "The layer is fully visible." : "The adjustment applies to the whole photo. Pick a mask above to limit it.")
                    .font(.system(size: 11))
                    .foregroundColor(.rpSlate)
                    .fixedSize(horizontal: false, vertical: true)
            case .brush:
                brushControls
                RPSlider(title: "Feather", value: binding(\.mask.feather), range: 0...100, defaultValue: 40,
                         format: { "\(Int($0.rounded()))" }, onCommit: { model.commit() })
            case .linear:
                Text("Fully applied at the solid handle, fading out by the hollow one.")
                    .font(.system(size: 11))
                    .foregroundColor(.rpSlate)
            case .radial:
                RPSlider(title: "Feather", value: binding(\.mask.feather), range: 0...100, defaultValue: 40,
                         format: { "\(Int($0.rounded()))" }, onCommit: { model.commit() })
            case .people, .sky, .subject, .background:
                autoControls
            }

            if layer.mask.mode != .none {
                HStack(spacing: 10) {
                    Toggle("Invert", isOn: committing(\.mask.inverted))
                    Toggle("Show mask", isOn: $model.showMaskOverlay)
                    Spacer()
                    if layer.mask.mode == .brush || layer.mask.mode.isAutomatic {
                        Button(layer.mask.mode.isAutomatic ? "Clear Touch-ups" : "Clear") {
                            model.updateSelectedLayer { $0.mask.strokes = [] }
                            model.commit()
                        }
                        .buttonStyle(RPButtonStyle())
                        .disabled(layer.mask.strokes.isEmpty)
                    }
                }
                .font(.system(size: 12))
            }
        }
    }

    private var brushControls: some View {
        VStack(spacing: 10) {
            Picker("", selection: $model.maskErase) {
                Label("Paint", systemImage: "paintbrush.pointed").tag(false)
                Label("Erase", systemImage: "eraser").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            RPSlider(title: "Brush Size", value: $model.maskBrushSize, range: 5...400, defaultValue: 60,
                     format: { "\(Int($0.rounded())) pt" }, onCommit: {})
        }
    }

    @ViewBuilder
    private var autoControls: some View {
        let mode = layer.mask.mode
        Text(mode.autoDescription)
            .font(.system(size: 11))
            .foregroundColor(.rpSlate)
            .fixedSize(horizontal: false, vertical: true)
        if mode.hasInstances && layer.mask.autoInstanceCount > 0 {
            let total = layer.mask.autoInstanceCount
            let included = total - layer.mask.autoExcluded.count
            HStack {
                Label("\(included) of \(total) \(mode == .people ? (total == 1 ? "person" : "people") : (total == 1 ? "subject" : "subjects")) selected",
                      systemImage: mode.icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.rpInk)
                Spacer()
                if !layer.mask.autoExcluded.isEmpty {
                    Button("Select All") { model.includeAllAutoInstances() }
                        .buttonStyle(RPButtonStyle())
                }
            }
        }
        if mode == .sky {
            RPSlider(title: "Sensitivity", value: binding(\.mask.autoSensitivity), range: 0...100, defaultValue: 50,
                     format: { "\(Int($0.rounded()))" },
                     onCommit: { model.applyAutoMask(.sky) })
                .help("Lower if the selection spills into buildings, water or haze; higher to reach further into clouds")
        }
        Toggle("Touch up with a brush", isOn: $model.refineAutoMask)
            .font(.system(size: 12))
        if model.refineAutoMask || !mode.hasInstances {
            brushControls
        }
        RPSlider(title: "Edge Softness", value: binding(\.mask.feather), range: 0...100, defaultValue: 20,
                 format: { "\(Int($0.rounded()))" }, onCommit: { model.commit() })
        Button {
            model.applyAutoMask(mode)
        } label: {
            Label("Detect Again", systemImage: "arrow.clockwise")
        }
        .buttonStyle(RPButtonStyle())
    }

    // MARK: Helpers

    private func colorBinding(_ key: WritableKeyPath<Layer, RGBAColor>) -> Binding<Color> {
        Binding(
            get: {
                let c = model.selectedLayer?[keyPath: key] ?? layer[keyPath: key]
                return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
            },
            set: { color in
                let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
                let c = RGBAColor(r: Double(ns.redComponent), g: Double(ns.greenComponent),
                                  b: Double(ns.blueComponent), a: Double(ns.alphaComponent))
                model.updateSelectedLayer { $0[keyPath: key] = c }
                model.commit()
            }
        )
    }

    private func labeled<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(.rpInk)
                .frame(width: 52, alignment: .leading)
            content()
        }
        .font(.system(size: 12))
    }
}
