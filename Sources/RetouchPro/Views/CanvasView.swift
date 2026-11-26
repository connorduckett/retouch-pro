import SwiftUI

struct CanvasView: View {
    @EnvironmentObject var model: EditorModel
    @State private var pinchBase: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let padding: CGFloat = 28
            let avail = CGSize(width: max(50, geo.size.width - padding * 2),
                               height: max(50, geo.size.height - padding * 2))
            let fit = fitSize(in: avail)
            let display = CGSize(width: fit.width * model.zoom, height: fit.height * model.zoom)

            Group {
                if model.zoom > 1.001 {
                    ScrollView([.horizontal, .vertical]) {
                        photo(size: display)
                            .padding(padding)
                            .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                    }
                } else {
                    photo(size: display)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .onAppear { model.viewportSize = avail }
            .onChange(of: geo.size) { _ in
                model.viewportSize = avail
                if model.zoom > 1 { model.scheduleRender() }
            }
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        if pinchBase == nil { pinchBase = model.zoom }
                        model.zoom = min(8, max(1, (pinchBase ?? 1) * value))
                    }
                    .onEnded { _ in pinchBase = nil }
            )
            .overlay(alignment: .bottom) { statusPill }
        }
        .background(NSWindowScaleReader { model.backingScale = $0 })
    }

    private var aspect: CGSize {
        let s = model.tool == .crop && !model.showOriginal ? model.frameSize : model.outputSize
        if model.showOriginal { return model.fullSize }
        return s == .zero ? CGSize(width: 3, height: 2) : s
    }

    private func fitSize(in avail: CGSize) -> CGSize {
        let a = aspect
        let scale = min(avail.width / a.width, avail.height / a.height)
        return CGSize(width: a.width * scale, height: a.height * scale)
    }

    @ViewBuilder
    private func photo(size: CGSize) -> some View {
        let image = model.showOriginal ? model.originalPreview : model.preview
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
            } else {
                Rectangle().fill(Color.rpSilver.opacity(0.3))
            }
            if !model.showOriginal {
                switch model.tool {
                case .crop: CropOverlay(size: size)
                case .heal: HealOverlay(size: size)
                default: EmptyView()
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
    }

    @ViewBuilder
    private var statusPill: some View {
        if model.showOriginal {
            pill("Showing original")
        } else if model.tool == .heal {
            pill("Click any spot, blemish or dust to remove it")
        } else if model.tool == .crop {
            pill("Drag the corners to crop · drag inside to move")
        }
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.rpCharcoal.opacity(0.92)))
            .padding(.bottom, 10)
            .allowsHitTesting(false)
    }
}

/// Reports the window's backing scale (2 on Retina) so previews render sharp.
struct NSWindowScaleReader: NSViewRepresentable {
    let onChange: (CGFloat) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { onChange(v.window?.backingScaleFactor ?? 2) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Heal overlay

struct HealOverlay: View {
    @EnvironmentObject var model: EditorModel
    let size: CGSize
    @State private var hover: CGPoint?

    var body: some View {
        ZStack {
            Color.white.opacity(0.001)
            ForEach(Array(model.healMarkers(displaySize: size).enumerated()), id: \.offset) { _, marker in
                Circle()
                    .stroke(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .frame(width: marker.1 * 2, height: marker.1 * 2)
                    .position(x: marker.0.x * size.width, y: marker.0.y * size.height)
            }
            if let hover {
                ZStack {
                    Circle().stroke(Color.black.opacity(0.45), lineWidth: 3)
                    Circle().stroke(Color.white, lineWidth: 1.5)
                }
                .frame(width: model.healBrushSize, height: model.healBrushSize)
                .position(hover)
                .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): hover = p
            case .ended: hover = nil
            }
        }
        .gesture(
            SpatialTapGesture().onEnded { value in
                let p = CGPoint(x: value.location.x / size.width, y: value.location.y / size.height)
                model.heal(atDisplayPoint: p, displaySize: size)
            }
        )
        .onHover { inside in
            if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
        }
    }
}
