import SwiftUI

struct InspectorView: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: model.tool.icon)
                Text(model.tool.title)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
            }
            .foregroundColor(.rpInk)
            .padding(.horizontal, 16)
            .frame(height: 44)
            Rectangle().fill(Color.rpMist).frame(height: 1)

            ScrollView {
                VStack(spacing: 12) {
                    switch model.tool {
                    case .adjust: AdjustPanel()
                    case .looks: LooksPanel()
                    case .crop: CropPanel()
                    case .heal: HealPanel()
                    }
                }
                .padding(12)
            }
        }
        .background(Color.rpPaper)
    }
}

// MARK: - Adjust

struct AdjustPanel: View {
    @EnvironmentObject var model: EditorModel

    private func slider(_ title: String, _ key: WritableKeyPath<Adjustments, Double>,
                        range: ClosedRange<Double> = -100...100, track: [Color]? = nil) -> some View {
        RPSlider(
            title: title,
            value: Binding(
                get: { model.state.adjustments[keyPath: key] },
                set: { model.state.adjustments[keyPath: key] = $0 }
            ),
            range: range,
            track: track,
            onCommit: { model.commit() }
        )
    }

    var body: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HistogramView(bins: model.histogram)
                Button {
                    model.autoEnhance()
                } label: {
                    Label("Auto Enhance", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(RPButtonStyle())
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.rpMist))

            SectionCard(title: "Light", onReset: { model.apply { $0.adjustments.resetLight() } }) {
                slider("Exposure", \.exposure)
                slider("Contrast", \.contrast)
                slider("Highlights", \.highlights)
                slider("Shadows", \.shadows)
                slider("Whites", \.whites)
                slider("Blacks", \.blacks)
            }
            SectionCard(title: "Color", onReset: { model.apply { $0.adjustments.resetColor() } }) {
                slider("Temperature", \.temperature, track: [Color(hex: 0x6E9BD6), Color(hex: 0xE2E2E2), Color(hex: 0xE3B85C)])
                slider("Tint", \.tint, track: [Color(hex: 0x7BBE7B), Color(hex: 0xE2E2E2), Color(hex: 0xC97BC4)])
                slider("Vibrance", \.vibrance)
                slider("Saturation", \.saturation)
            }
            SectionCard(title: "Detail", onReset: { model.apply { $0.adjustments.resetDetail() } }) {
                slider("Clarity", \.clarity)
                slider("Sharpen", \.sharpness, range: 0...100)
                slider("Noise Reduction", \.noiseReduction, range: 0...100)
            }
            SectionCard(title: "Effects", onReset: { model.apply { $0.adjustments.resetEffects() } }) {
                slider("Vignette", \.vignette)
                slider("Grain", \.grain, range: 0...100)
                slider("Fade", \.fade, range: 0...100)
            }

            Text("Tip: double-click any slider’s name to reset it.")
                .font(.system(size: 11))
                .foregroundColor(.rpSlate)
                .padding(.top, 2)
        }
    }
}

// MARK: - Looks

struct LooksPanel: View {
    @EnvironmentObject var model: EditorModel
    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        VStack(spacing: 12) {
            if model.state.lookID != nil {
                SectionCard(title: "Strength") {
                    RPSlider(
                        title: Look.find(model.state.lookID)?.name ?? "Look",
                        value: Binding(get: { model.state.lookAmount }, set: { model.state.lookAmount = $0 }),
                        range: 0...100,
                        format: { "\(Int($0.rounded()))%" },
                        onCommit: { model.commit() }
                    )
                }
            }

            LazyVGrid(columns: columns, spacing: 10) {
                LookTile(id: nil, name: "Original")
                ForEach(Look.all) { look in
                    LookTile(id: look.id, name: look.name)
                }
            }
            Text("Looks sit on top of your Adjust settings, so you can still fine-tune.")
                .font(.system(size: 11))
                .foregroundColor(.rpSlate)
                .multilineTextAlignment(.center)
        }
    }
}

private struct LookTile: View {
    @EnvironmentObject var model: EditorModel
    let id: String?
    let name: String
    @State private var hover = false

    var selected: Bool { model.state.lookID == id }

    var body: some View {
        Button {
            model.apply {
                $0.lookID = id
                $0.lookAmount = 100
            }
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Color.rpMist
                    if let thumb = model.lookThumbnails[id ?? "none"] {
                        Image(nsImage: thumb).resizable().scaledToFill()
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(selected ? Color.rpCharcoal : (hover ? Color.rpSilver : .clear), lineWidth: selected ? 3 : 1)
                )
                Text(name)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .foregroundColor(selected ? .rpInk : .rpCharcoal)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Crop

struct CropPanel: View {
    @EnvironmentObject var model: EditorModel
    private let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6),
                           GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    var body: some View {
        VStack(spacing: 12) {
            SectionCard(title: "Aspect Ratio") {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(AspectRatio.allCases) { ratio in
                        ChipButton(title: ratio.rawValue, selected: model.cropAspect == ratio) {
                            model.cropAspect = ratio
                            model.cropIsLandscapeFlipped = false
                            model.applyAspect()
                        }
                    }
                }
                if model.cropAspect != .free && model.cropAspect != .square && model.cropAspect != .original {
                    Button {
                        model.swapAspectOrientation()
                    } label: {
                        Label("Swap Portrait / Landscape", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(RPButtonStyle())
                }
            }

            SectionCard(title: "Straighten") {
                RPSlider(
                    title: "Angle",
                    value: Binding(get: { model.state.straighten }, set: { model.state.straighten = $0 }),
                    range: -45...45,
                    format: { String(format: "%.1f°", $0) },
                    onCommit: { model.commit() }
                )
            }

            SectionCard(title: "Rotate & Flip") {
                HStack(spacing: 6) {
                    BigToolButton(title: "Left", systemImage: "rotate.left") { model.rotateLeft() }
                    BigToolButton(title: "Right", systemImage: "rotate.right") { model.rotateRight() }
                    BigToolButton(title: "Flip H", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") { model.flipHorizontal() }
                    BigToolButton(title: "Flip V", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down") { model.flipVertical() }
                }
            }

            HStack {
                Button("Reset Crop") { model.resetCrop() }
                    .buttonStyle(RPButtonStyle())
                Spacer()
                Button {
                    model.tool = .adjust
                } label: {
                    Label("Done", systemImage: "checkmark")
                }
                .buttonStyle(RPButtonStyle(kind: .primary))
            }
            .padding(.top, 4)
        }
    }
}

// MARK: - Heal

struct HealPanel: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        VStack(spacing: 12) {
            SectionCard(title: "Spot Healing") {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "hand.point.up.left")
                        .foregroundColor(.rpCharcoal)
                    Text("Click on blemishes, dust spots or small distractions. Retouch Pro finds matching texture nearby and blends it in.")
                        .font(.system(size: 12))
                        .foregroundColor(.rpInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                RPSlider(
                    title: "Brush Size",
                    value: $model.healBrushSize,
                    range: 8...200,
                    format: { "\(Int($0.rounded())) pt" },
                    onCommit: {}
                )
                Text("Tip: zoom in (⌘+) for tiny spots.")
                    .font(.system(size: 11))
                    .foregroundColor(.rpSlate)
            }

            SectionCard(title: "Spots") {
                HStack {
                    Text(model.state.heals.isEmpty ? "No spots removed yet" :
                            "\(model.state.heals.count) spot\(model.state.heals.count == 1 ? "" : "s") removed")
                        .font(.system(size: 12))
                        .foregroundColor(.rpInk)
                    Spacer()
                }
                HStack(spacing: 8) {
                    Button("Undo Last") {
                        model.apply { _ = $0.heals.popLast() }
                    }
                    .buttonStyle(RPButtonStyle())
                    .disabled(model.state.heals.isEmpty)
                    Button("Clear All") {
                        model.apply { $0.heals.removeAll() }
                    }
                    .buttonStyle(RPButtonStyle())
                    .disabled(model.state.heals.isEmpty)
                    Spacer()
                }
            }
        }
    }
}
