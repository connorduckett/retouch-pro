import SwiftUI

/// A large, friendly slider with a center "zero" mark, value readout,
/// and double-click-the-label to reset.
struct RPSlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = -100...100
    var track: [Color]? = nil
    var format: (Double) -> String = { v in
        let r = Int(v.rounded())
        return r > 0 ? "+\(r)" : "\(r)"
    }
    var onCommit: () -> Void

    @State private var dragging = false

    var body: some View {
        VStack(spacing: 7) {
            HStack {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundColor(.rpInk)
                Spacer()
                Text(format(value))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundColor(abs(value) < 0.5 ? .rpSlate : .rpInk)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                value = 0
                onCommit()
            }
            .help("Double-click to reset")

            GeometryReader { geo in
                let w = geo.size.width
                let x = position(value, width: w)
                let zeroX = position(min(max(0, range.lowerBound), range.upperBound), width: w)
                ZStack(alignment: .leading) {
                    Group {
                        if let track {
                            Capsule().fill(LinearGradient(colors: track, startPoint: .leading, endPoint: .trailing))
                                .opacity(0.75)
                        } else {
                            Capsule().fill(Color.rpMist)
                        }
                    }
                    .frame(height: 4)

                    if track == nil {
                        Rectangle()
                            .fill(Color.rpCharcoal)
                            .frame(width: abs(x - zeroX), height: 4)
                            .offset(x: min(x, zeroX))
                    }
                    if range.lowerBound < 0 {
                        Rectangle().fill(Color.rpSilver).frame(width: 1, height: 9).offset(x: zeroX - 0.5)
                    }
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().stroke(dragging ? Color.rpCharcoal : Color.rpSilver, lineWidth: dragging ? 2 : 1))
                        .shadow(color: .black.opacity(0.15), radius: 1.5, y: 1)
                        .frame(width: 15, height: 15)
                        .offset(x: x - 7.5)
                }
                .frame(height: 18)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            dragging = true
                            let t = min(max(0, g.location.x / w), 1)
                            var v = range.lowerBound + t * (range.upperBound - range.lowerBound)
                            if range.lowerBound < 0, abs(v) < (range.upperBound - range.lowerBound) * 0.012 { v = 0 }   // snap to zero
                            value = v
                        }
                        .onEnded { _ in
                            dragging = false
                            onCommit()
                        }
                )
            }
            .frame(height: 18)
        }
    }

    private func position(_ v: Double, width: CGFloat) -> CGFloat {
        let t = (min(max(v, range.lowerBound), range.upperBound) - range.lowerBound) / (range.upperBound - range.lowerBound)
        return CGFloat(t) * width
    }
}

struct HistogramView: View {
    let bins: [Double]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.rpPaper)
                if bins.count == 256 {
                    Path { p in
                        let w = geo.size.width, h = geo.size.height - 6
                        p.move(to: CGPoint(x: 0, y: geo.size.height))
                        for (i, v) in bins.enumerated() {
                            let x = CGFloat(i) / 255 * w
                            p.addLine(to: CGPoint(x: x, y: geo.size.height - CGFloat(v) * h))
                        }
                        p.addLine(to: CGPoint(x: w, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [.rpSlate, .rpCharcoal], startPoint: .top, endPoint: .bottom))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                HStack {
                    ForEach(1..<4) { _ in
                        Spacer()
                        Rectangle().fill(Color.white.opacity(0.5)).frame(width: 1)
                    }
                    Spacer()
                }
                .allowsHitTesting(false)
            }
        }
        .frame(height: 74)
    }
}

struct ChipButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(selected ? .white : .rpInk)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.rpCharcoal : Color.rpPaper))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.clear : Color.rpMist))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct BigToolButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 16))
                Text(title).font(.system(size: 10.5, weight: .medium))
            }
            .foregroundColor(.rpCharcoal)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(RoundedRectangle(cornerRadius: 8).fill(hover ? Color.rpMist : Color.rpPaper))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
