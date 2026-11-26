import SwiftUI

/// On-canvas editing for the selected layer: mask painting, gradient handles,
/// moving/resizing text & shapes, and the pen tool.
struct LayersOverlay: View {
    @EnvironmentObject var model: EditorModel
    let size: CGSize

    var body: some View {
        if let layer = model.selectedLayer, layer.visible {
            if layer.kind == .adjustment || model.editingMask {
                MaskEditor(layer: layer, size: size)
            } else if layer.kind == .path {
                PenEditor(layer: layer, size: size)
            } else {
                FrameEditor(frame: layer.frame, size: size)
            }
        }
    }
}

// MARK: - Handle

struct Handle: View {
    var diameter: CGFloat = 12
    var filled = true

    var body: some View {
        ZStack {
            Color.white.opacity(0.001).frame(width: 26, height: 26)
            Circle()
                .fill(filled ? Color.white : Color.clear)
                .overlay(Circle().stroke(Color.rpAccent, lineWidth: 2))
                .frame(width: diameter, height: diameter)
                .shadow(color: .black.opacity(0.35), radius: 1.5)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Mask editor

private struct MaskEditor: View {
    @EnvironmentObject var model: EditorModel
    let layer: Layer
    let size: CGSize

    private func view(_ src: [Double]) -> CGPoint {
        let d = model.sourceToDisplay(CGPoint(x: src[0], y: src[1]))
        return CGPoint(x: d.x * size.width, y: d.y * size.height)
    }

    private func source(_ viewPoint: CGPoint) -> [Double] {
        let s = model.displayToSource(CGPoint(x: viewPoint.x / size.width, y: viewPoint.y / size.height))
        return [Double(s.x), Double(s.y)]
    }

    var body: some View {
        switch layer.mask.mode {
        case .none:
            EmptyView()
        case .brush:
            BrushOverlay(size: size, diameter: model.maskBrushSize, tint: model.maskErase ? .white : .red) { pts in
                model.addMaskStroke(displayPoints: pts, displaySize: size)
            }
        case .linear:
            linear
        case .radial:
            radial
        }
    }

    private var linear: some View {
        let a = view(layer.mask.start), b = view(layer.mask.end)
        let dir = CGPoint(x: b.x - a.x, y: b.y - a.y)
        let len = max(1, hypot(dir.x, dir.y))
        let perp = CGPoint(x: -dir.y / len * 2000, y: dir.x / len * 2000)
        return ZStack {
            Path { p in
                for c in [a, b] {
                    p.move(to: CGPoint(x: c.x - perp.x, y: c.y - perp.y))
                    p.addLine(to: CGPoint(x: c.x + perp.x, y: c.y + perp.y))
                }
            }
            .stroke(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            Path { p in p.move(to: a); p.addLine(to: b) }
                .stroke(Color.white, lineWidth: 1.5)
            Handle().position(a).gesture(drag { _, loc in model.updateSelectedLayer { $0.mask.start = source(loc) } })
            Handle(filled: false).position(b).gesture(drag { _, loc in model.updateSelectedLayer { $0.mask.end = source(loc) } })
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private var radial: some View {
        let m = layer.mask
        let c = view(m.center)
        let rx = model.sourceLengthToDisplay(m.radiusX, displayWidth: size.width)
        let ry = model.sourceLengthToDisplay(m.radiusY, displayWidth: size.width)
        return ZStack {
            Ellipse()
                .stroke(Color.white, lineWidth: 1.5)
                .frame(width: rx * 2, height: ry * 2)
                .position(c)
                .allowsHitTesting(false)
            Ellipse()
                .stroke(Color.white.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .frame(width: rx * 2 * (1 - m.feather / 100), height: ry * 2 * (1 - m.feather / 100))
                .position(c)
                .allowsHitTesting(false)
            Handle().position(c).gesture(drag { _, loc in model.updateSelectedLayer { $0.mask.center = source(loc) } })
            Handle(diameter: 10, filled: false).position(x: c.x + rx, y: c.y).gesture(drag { _, loc in
                let w = model.displayLengthToSource(abs(loc.x - c.x), displayWidth: size.width)
                model.updateSelectedLayer { $0.mask.radiusX = max(0.01, w) }
            })
            Handle(diameter: 10, filled: false).position(x: c.x, y: c.y - ry).gesture(drag { _, loc in
                let h = model.displayLengthToSource(abs(loc.y - c.y), displayWidth: size.width)
                model.updateSelectedLayer { $0.mask.radiusY = max(0.01, h) }
            })
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    /// Drag helper: calls `update(model, location)` live and commits when the drag ends.
    private func drag(_ update: @escaping (EditorModel, CGPoint) -> Void) -> some Gesture {
        DragGesture(coordinateSpace: .named("layerCanvas"))
            .onChanged { v in update(model, v.location) }
            .onEnded { _ in model.commit() }
    }
}

// MARK: - Frame editor (text & shapes)

struct FrameEditor: View {
    @EnvironmentObject var model: EditorModel
    let frame: CGRect   // normalized, top-left origin
    let size: CGSize
    @State private var start: CGRect?

    private enum Edge: CaseIterable { case tl, t, tr, r, br, b, bl, l }

    var body: some View {
        let r = CGRect(x: frame.minX * size.width, y: frame.minY * size.height,
                       width: frame.width * size.width, height: frame.height * size.height)
        ZStack {
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .overlay(Rectangle().stroke(Color.white, style: StrokeStyle(lineWidth: 1, dash: [5, 3])))
                .overlay(Rectangle().stroke(Color.black.opacity(0.3), lineWidth: 0.5).padding(-1))
                .frame(width: max(4, r.width), height: max(4, r.height))
                .position(x: r.midX, y: r.midY)
                .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
                .gesture(
                    DragGesture()
                        .onChanged { v in
                            let s = start ?? frame
                            if start == nil { start = s }
                            set(s.offsetBy(dx: v.translation.width / size.width, dy: v.translation.height / size.height))
                        }
                        .onEnded { _ in start = nil; model.commit() }
                )
            ForEach(Edge.allCases, id: \.self) { e in
                Handle(diameter: 10)
                    .position(point(e, r))
                    .gesture(
                        DragGesture()
                            .onChanged { v in
                                let s = start ?? frame
                                if start == nil { start = s }
                                set(resize(s, e, dx: v.translation.width / size.width, dy: v.translation.height / size.height))
                            }
                            .onEnded { _ in start = nil; model.commit() }
                    )
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func set(_ f: CGRect) {
        model.updateSelectedLayer { $0.frame = f }
    }

    private func point(_ e: Edge, _ r: CGRect) -> CGPoint {
        switch e {
        case .tl: return CGPoint(x: r.minX, y: r.minY)
        case .t: return CGPoint(x: r.midX, y: r.minY)
        case .tr: return CGPoint(x: r.maxX, y: r.minY)
        case .r: return CGPoint(x: r.maxX, y: r.midY)
        case .br: return CGPoint(x: r.maxX, y: r.maxY)
        case .b: return CGPoint(x: r.midX, y: r.maxY)
        case .bl: return CGPoint(x: r.minX, y: r.maxY)
        case .l: return CGPoint(x: r.minX, y: r.midY)
        }
    }

    private func resize(_ s: CGRect, _ e: Edge, dx: CGFloat, dy: CGFloat) -> CGRect {
        var minX = s.minX, maxX = s.maxX, minY = s.minY, maxY = s.maxY
        let minSize: CGFloat = 0.01
        if [.tl, .l, .bl].contains(e) { minX = min(minX + dx, maxX - minSize) }
        if [.tr, .r, .br].contains(e) { maxX = max(maxX + dx, minX + minSize) }
        if [.tl, .t, .tr].contains(e) { minY = min(minY + dy, maxY - minSize) }
        if [.bl, .b, .br].contains(e) { maxY = max(maxY + dy, minY + minSize) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

// MARK: - Pen tool

private struct PenEditor: View {
    @EnvironmentObject var model: EditorModel
    let layer: Layer
    let size: CGSize

    private var points: [CGPoint] {
        layer.pathPoints.compactMap { $0.count == 2 ? CGPoint(x: $0[0] * size.width, y: $0[1] * size.height) : nil }
    }

    var body: some View {
        let pts = points
        ZStack {
            if model.penActive {
                Color.white.opacity(0.001)
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { v in addPoint(v.location) })
                    .onHover { inside in if inside { NSCursor.crosshair.push() } else { NSCursor.pop() } }
            }
            Path(LayerRenderer.penPath(points: pts, closed: layer.pathClosed, smooth: layer.pathSmooth))
                .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .allowsHitTesting(false)
            ForEach(Array(pts.enumerated()), id: \.offset) { i, p in
                Handle(diameter: i == 0 ? 12 : 9, filled: i != 0)
                    .position(p)
                    .help(i == 0 && pts.count >= 3 && !layer.pathClosed ? "Click to close the path" : "Drag to move")
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("layerCanvas"))
                            .onChanged { v in
                                guard hypot(v.translation.width, v.translation.height) > 2 else { return }
                                let x = min(max(0, v.location.x / size.width), 1)
                                let y = min(max(0, v.location.y / size.height), 1)
                                model.updateSelectedLayer { $0.pathPoints[i] = [x, y] }
                            }
                            .onEnded { v in
                                if hypot(v.translation.width, v.translation.height) <= 2,
                                   i == 0, pts.count >= 3, !layer.pathClosed {
                                    model.updateSelectedLayer { $0.pathClosed = true }
                                }
                                model.commit()
                            }
                    )
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func addPoint(_ p: CGPoint) {
        guard !layer.pathClosed else { return }
        model.apply { state in
            guard let i = state.layers.firstIndex(where: { $0.id == layer.id }) else { return }
            state.layers[i].pathPoints.append([p.x / size.width, p.y / size.height])
        }
    }
}
