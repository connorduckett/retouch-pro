import SwiftUI

struct CropOverlay: View {
    @EnvironmentObject var model: EditorModel
    let size: CGSize
    @State private var startRect: CGRect?

    private let minSize = 0.05

    enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
        var movesLeft: Bool { [.topLeft, .left, .bottomLeft].contains(self) }
        var movesRight: Bool { [.topRight, .right, .bottomRight].contains(self) }
        var movesTop: Bool { [.topLeft, .top, .topRight].contains(self) }
        var movesBottom: Bool { [.bottomLeft, .bottom, .bottomRight].contains(self) }
        var isCorner: Bool { [.topLeft, .topRight, .bottomLeft, .bottomRight].contains(self) }
        var isVerticalEdge: Bool { self == .left || self == .right }
    }

    var body: some View {
        let r = viewRect(model.state.crop)
        ZStack {
            // Dim everything outside the crop.
            Path { p in
                p.addRect(CGRect(origin: .zero, size: size))
                p.addRect(r)
            }
            .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            // Rule-of-thirds grid.
            Path { p in
                for i in 1...2 {
                    let x = r.minX + r.width * CGFloat(i) / 3
                    let y = r.minY + r.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
                    p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.5), lineWidth: 0.75)
            .allowsHitTesting(false)

            // Move area.
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)
                .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
                .gesture(
                    DragGesture()
                        .onChanged { v in
                            let s = startRect ?? model.state.crop
                            if startRect == nil { startRect = s }
                            let dx = v.translation.width / size.width
                            let dy = -v.translation.height / size.height
                            var n = s.offsetBy(dx: dx, dy: dy)
                            n.origin.x = min(max(0, n.minX), 1 - n.width)
                            n.origin.y = min(max(0, n.minY), 1 - n.height)
                            model.state.crop = n
                        }
                        .onEnded { _ in startRect = nil; model.commit() }
                )

            Rectangle()
                .stroke(Color.white, lineWidth: 1.5)
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)
                .allowsHitTesting(false)

            ForEach(Handle.allCases, id: \.self) { handle in
                handleView(handle)
                    .position(point(for: handle, in: r))
                    .gesture(
                        DragGesture()
                            .onChanged { v in
                                let s = startRect ?? model.state.crop
                                if startRect == nil { startRect = s }
                                model.state.crop = resized(
                                    s, handle: handle,
                                    dx: v.translation.width / size.width,
                                    dy: -v.translation.height / size.height)
                            }
                            .onEnded { _ in startRect = nil; model.commit() }
                    )
            }
        }
        .frame(width: size.width, height: size.height)
    }

    // MARK: Geometry

    /// Normalized (bottom-left origin) → view (top-left origin).
    private func viewRect(_ n: CGRect) -> CGRect {
        CGRect(x: n.minX * size.width,
               y: (1 - n.maxY) * size.height,
               width: n.width * size.width,
               height: n.height * size.height)
    }

    private func point(for h: Handle, in r: CGRect) -> CGPoint {
        let x: CGFloat = h.movesLeft ? r.minX : h.movesRight ? r.maxX : r.midX
        let y: CGFloat = h.movesTop ? r.minY : h.movesBottom ? r.maxY : r.midY
        return CGPoint(x: x, y: y)
    }

    @ViewBuilder
    private func handleView(_ h: Handle) -> some View {
        let hit: CGFloat = 26
        ZStack {
            Color.white.opacity(0.001)
            if h.isCorner {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white)
                    .frame(width: 12, height: 12)
                    .shadow(color: .black.opacity(0.4), radius: 1.5)
            } else {
                Capsule()
                    .fill(Color.white)
                    .frame(width: h.isVerticalEdge ? 5 : 22, height: h.isVerticalEdge ? 22 : 5)
                    .shadow(color: .black.opacity(0.4), radius: 1.5)
            }
        }
        .frame(width: hit, height: hit)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                (h.isCorner ? NSCursor.crosshair : h.isVerticalEdge ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
            } else { NSCursor.pop() }
        }
    }

    private func resized(_ s: CGRect, handle h: Handle, dx: Double, dy: Double) -> CGRect {
        var minX = s.minX, maxX = s.maxX, minY = s.minY, maxY = s.maxY
        if h.movesLeft { minX = min(max(0, minX + dx), maxX - minSize) }
        if h.movesRight { maxX = max(min(1, maxX + dx), minX + minSize) }
        if h.movesTop { maxY = max(min(1, maxY + dy), minY + minSize) }
        if h.movesBottom { minY = min(max(0, minY + dy), maxY - minSize) }

        guard var ratio = model.lockedAspect else {
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        if model.cropIsLandscapeFlipped { ratio = 1 / ratio }
        let frame = model.frameSize
        guard frame.width > 0, frame.height > 0 else { return s }
        // normalized height = normalized width × k keeps the pixel ratio.
        let k = Double(frame.width) / (ratio * Double(frame.height))
        var w = maxX - minX, ht = maxY - minY

        if h.isCorner {
            if w * k > ht { ht = w * k } else { w = ht / k }
            let anchorX = h.movesLeft ? s.maxX : s.minX
            let anchorY = h.movesBottom ? s.maxY : s.minY
            let availW = h.movesLeft ? anchorX : 1 - anchorX
            let availH = h.movesBottom ? anchorY : 1 - anchorY
            let scale = min(1, availW / w, availH / ht)
            w *= scale; ht *= scale
            let x = h.movesLeft ? anchorX - w : anchorX
            let y = h.movesBottom ? anchorY - ht : anchorY
            return CGRect(x: x, y: y, width: w, height: ht)
        } else if h.isVerticalEdge {
            ht = w * k
            let mid = s.midY
            let availH = 2 * min(mid, 1 - mid)
            if ht > availH { ht = availH; w = ht / k }
            let x = h.movesLeft ? s.maxX - w : s.minX
            return CGRect(x: x, y: mid - ht / 2, width: w, height: ht)
        } else {
            w = ht / k
            let mid = s.midX
            let availW = 2 * min(mid, 1 - mid)
            if w > availW { w = availW; ht = w * k }
            let y = h.movesBottom ? s.maxY - ht : s.minY
            return CGRect(x: mid - w / 2, y: y, width: w, height: ht)
        }
    }
}
