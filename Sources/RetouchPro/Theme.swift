import AppKit
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

    /// A color that follows the app's light/dark appearance.
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let v = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                           green: CGFloat((v >> 8) & 0xFF) / 255,
                           blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        })
    }

    // Palette: #6A6A6A · #979797 · #BDBDBD · #E2E2E2 · #F8F8F8 (mirrored for dark mode)

    /// Icons and secondary labels.
    static let rpCharcoal = dynamic(light: 0x6A6A6A, dark: 0xBDBDBD)
    /// Solid accent fill behind white text (primary button, selected tool).
    static let rpAccent = dynamic(light: 0x6A6A6A, dark: 0x6A6A6A)
    /// Secondary text and icons.
    static let rpSlate = dynamic(light: 0x979797, dark: 0x979797)
    /// Borders and inactive controls.
    static let rpSilver = dynamic(light: 0xBDBDBD, dark: 0x4A4A4A)
    /// Canvas backdrop, hover and selection fills.
    static let rpMist = dynamic(light: 0xE2E2E2, dark: 0x2C2C2C)
    /// Panels and bars.
    static let rpPaper = dynamic(light: 0xF8F8F8, dark: 0x1E1E1E)
    /// Cards inside panels.
    static let rpCard = dynamic(light: 0xFFFFFF, dark: 0x262626)
    /// Slider knobs.
    static let rpThumb = dynamic(light: 0xFFFFFF, dark: 0xE2E2E2)
    /// Body text.
    static let rpInk = dynamic(light: 0x3D3D3D, dark: 0xF8F8F8)
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system = "System", light = "Light", dark = "Dark"
    var id: String { rawValue }

    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
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
        case .primary: return pressed ? .rpSlate : .rpAccent
        case .secondary: return pressed ? .rpMist : .rpCard
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
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.rpCard))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.rpMist, lineWidth: 1))
    }
}
