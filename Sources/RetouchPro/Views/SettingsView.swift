import SwiftUI

enum SettingsKey {
    static let appearance = "appearance"
    static let autoStyle = "autoEnhanceStyle"
    static let exportFormat = "defaultExportFormat"
    static let exportQuality = "defaultExportQuality"
    static let exportColor = "defaultExportColor"
    static let keepMetadata = "defaultKeepMetadata"
    static let showHealMarkers = "showHealMarkers"
    static let confirmDiscard = "confirmDiscard"
}

enum AutoEnhanceStyle: String, CaseIterable, Identifiable {
    case signature = "Signature"
    case natural = "Natural"
    var id: String { rawValue }

    var description: String {
        switch self {
        case .signature:
            return "Bright, airy and warm with soft, lifted blacks and gentle color — tuned from a professional wedding & portrait portfolio."
        case .natural:
            return "Neutral correction: fixes exposure and contrast without adding a style."
        }
    }
}

struct SettingsView: View {
    @AppStorage(SettingsKey.appearance) private var appearance = AppearanceMode.system.rawValue
    @AppStorage(SettingsKey.autoStyle) private var autoStyle = AutoEnhanceStyle.signature.rawValue
    @AppStorage(SettingsKey.exportFormat) private var exportFormat = EditorModel.ExportOptions.Format.jpeg.rawValue
    @AppStorage(SettingsKey.exportQuality) private var exportQuality = 90.0
    @AppStorage(SettingsKey.exportColor) private var exportColor = EditorModel.ExportOptions.ColorProfile.sRGB.rawValue
    @AppStorage(SettingsKey.keepMetadata) private var keepMetadata = true
    @AppStorage(SettingsKey.showHealMarkers) private var showHealMarkers = false
    @AppStorage(SettingsKey.confirmDiscard) private var confirmDiscard = true

    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                tabButton(0, "General", "gearshape")
                tabButton(1, "Editing", "slider.horizontal.3")
                tabButton(2, "Export", "square.and.arrow.up")
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Color.rpPaper)
            Rectangle().fill(Color.rpMist).frame(height: 1)

            VStack(alignment: .leading, spacing: 16) {
                switch tab {
                case 0: general
                case 1: editing
                default: export
                }
                Spacer(minLength: 0)
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 520, height: 400)
        .background(Color.rpCard)
    }

    private func tabButton(_ index: Int, _ title: String, _ icon: String) -> some View {
        Button {
            tab = index
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 18)).frame(height: 22)
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(tab == index ? .white : .rpCharcoal)
            .frame(width: 84, height: 52)
            .background(RoundedRectangle(cornerRadius: 9).fill(tab == index ? Color.rpAccent : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingRow("Appearance") {
                Picker("", selection: $appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
                .onChange(of: appearance) { value in
                    (AppearanceMode(rawValue: value) ?? .system).apply()
                }
            }
            caption("Dark mode is easier on the eyes for long editing sessions. “System” follows your Mac.")

            settingRow("") {
                Toggle("Warn before closing a photo with unexported edits", isOn: $confirmDiscard)
            }
        }
    }

    private var editing: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingRow("Auto Enhance") {
                Picker("", selection: $autoStyle) {
                    ForEach(AutoEnhanceStyle.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
            }
            caption((AutoEnhanceStyle(rawValue: autoStyle) ?? .signature).description)

            settingRow("Healing") {
                Toggle("Outline healed spots while using the Heal tool", isOn: $showHealMarkers)
            }

            settingRow("Sliders") {
                Text("Double-click a slider (or Option-click it) to reset it.")
                    .font(.system(size: 12))
                    .foregroundColor(.rpSlate)
            }
        }
    }

    private var export: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingRow("Format") {
                Picker("", selection: $exportFormat) {
                    ForEach(EditorModel.ExportOptions.Format.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
            }
            settingRow("Quality") {
                RPSlider(title: "JPEG / HEIC", value: $exportQuality, range: 40...100, defaultValue: 90,
                         format: { "\(Int($0.rounded()))" }, onCommit: {})
                    .frame(width: 260)
            }
            settingRow("Color") {
                Picker("", selection: $exportColor) {
                    ForEach(EditorModel.ExportOptions.ColorProfile.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
            }
            settingRow("") {
                Toggle("Keep camera info (EXIF, copyright, GPS)", isOn: $keepMetadata)
            }
            caption("These are the starting choices each time you open the Export window.")
        }
    }

    private func settingRow<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.rpCharcoal)
                .frame(width: 100, alignment: .trailing)
            content()
                .font(.system(size: 12))
                .foregroundColor(.rpInk)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(.rpSlate)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 114)
            .padding(.top, -10)
    }
}
