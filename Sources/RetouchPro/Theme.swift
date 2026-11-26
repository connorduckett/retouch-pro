import SwiftUI

/// Retouch Pro palette — a calm, neutral grayscale so photos are judged
/// against gray, never against a colored UI.
extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }

    /// #6A6A6A — primary accent: active tools, filled tracks, primary button.
    static let rpCharcoal = Color(hex: 0x6A6A6A)
    /// #979797 — secondary text and icons.
    static let rpSlate = Color(hex: 0x979797)
    /// #BDBDBD — borders and inactive controls.
    static let rpSilver = Color(hex: 0xBDBDBD)
    /// #E2E2E2 — canvas backdrop, hover and selection fills.
    static let rpMist = Color(hex: 0xE2E2E2)
    /// #F8F8F8 — panels and bars.
    static let rpPaper = Color(hex: 0xF8F8F8)
    /// Darkened charcoal used only for body text so it stays readable.
    static let rpInk = Color(hex: 0x3D3D3D)
}

struct RPButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, plain }
    var kind: Kind = .secondary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundColor(kind == .primary ? .white : .rpInk)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(background(pressed: configuration.isPressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(kind == .secondary ? Color.rpSilver : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
    }

    private func background(pressed: Bool) -> Color {
        switch kind {
        case .primary: return pressed ? .rpInk : .rpCharcoal
        case .secondary: return pressed ? .rpMist : .white
        case .plain: return pressed ? .rpMist : .clear
        }
    }
}

struct IconButton: View {
    let systemName: String
    let help: String
    var disabled = false
    let action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 28)
                .foregroundColor(disabled ? .rpSilver : .rpCharcoal)
                .background(
                    RoundedRectangle(cornerRadius: 6).fill(hover && !disabled ? Color.rpMist : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        .onHover { hover = $0 }
    }
}

struct SectionCard<Content: View>: View {
    let title: String
    var onReset: (() -> Void)? = nil
    @ViewBuilder var content: Content
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        Text(title.uppercased())
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(0.6)
                    }
                    .foregroundColor(.rpCharcoal)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                if let onReset {
                    Button("Reset", action: onReset)
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(.rpSlate)
                }
            }
            if expanded {
                content
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.rpMist, lineWidth: 1))
    }
}
