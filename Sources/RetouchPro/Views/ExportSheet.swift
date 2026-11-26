import AppKit
import SwiftUI

struct ExportSheet: View {
    @EnvironmentObject var model: EditorModel
    @Binding var isPresented: Bool
    @State private var error: String?
    @State private var done: URL?

    private let sizes: [(String, Int?)] = [
        ("Full size", nil), ("4096 px", 4096), ("2048 px (web)", 2048), ("1080 px (social)", 1080),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 18))
                Text("Export Photo")
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundColor(.rpInk)

            if let done {
                successView(done)
            } else {
                form
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(Color.rpPaper)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 18) {
            row("Format") {
                Picker("", selection: $model.exportOptions.format) {
                    ForEach(EditorModel.ExportOptions.Format.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if model.exportOptions.format.isLossy {
                row("Quality") {
                    RPSlider(title: qualityLabel, value: $model.exportOptions.quality, range: 40...100,
                             format: { "\(Int($0.rounded()))" }, onCommit: {})
                }
            }

            row("Size") {
                Picker("", selection: $model.exportOptions.longEdge) {
                    ForEach(sizes, id: \.0) { Text($0.0).tag($0.1) }
                }
                .labelsHidden()
            }

            row("Color") {
                Picker("", selection: $model.exportOptions.colorProfile) {
                    ForEach(EditorModel.ExportOptions.ColorProfile.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Text("sRGB is best for the web, social media and most print labs.")
                .font(.system(size: 11))
                .foregroundColor(.rpSlate)
                .padding(.leading, 92)
                .padding(.top, -12)

            row("") {
                Toggle("Keep camera info (EXIF, copyright, GPS)", isOn: $model.exportOptions.keepMetadata)
                    .font(.system(size: 12))
            }

            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $model.exportOptions.watermark) {
                    Text("Add watermark").font(.system(size: 12, weight: .medium))
                }
                if model.exportOptions.watermark {
                    TextField("© Your Name Photography", text: $model.exportOptions.watermarkText)
                        .textFieldStyle(.roundedBorder)
                    Picker("Position", selection: $model.exportOptions.watermarkPosition) {
                        ForEach(EditorModel.ExportOptions.WatermarkPosition.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .font(.system(size: 12))
                    RPSlider(title: "Size", value: $model.exportOptions.watermarkSize, range: 1...10,
                             format: { String(format: "%.1f%%", $0) }, onCommit: {})
                    RPSlider(title: "Opacity", value: $model.exportOptions.watermarkOpacity, range: 10...100,
                             format: { "\(Int($0.rounded()))%" }, onCommit: {})
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.rpMist))

            if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
            }

            HStack {
                Text(outputDescription)
                    .font(.system(size: 11))
                    .foregroundColor(.rpSlate)
                Spacer()
                Button("Cancel") { isPresented = false }
                    .buttonStyle(RPButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button {
                    chooseDestination()
                } label: {
                    if model.isExporting {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small).colorInvert()
                            Text("Exporting…")
                        }
                    } else {
                        Text("Export…")
                    }
                }
                .buttonStyle(RPButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(model.isExporting)
            }
        }
    }

    private func successView(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.rpCharcoal)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Saved!").font(.system(size: 14, weight: .semibold)).foregroundColor(.rpInk)
                    Text(url.lastPathComponent).font(.system(size: 12)).foregroundColor(.rpSlate)
                }
            }
            HStack {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .buttonStyle(RPButtonStyle())
                Spacer()
                Button("Done") { isPresented = false }
                    .buttonStyle(RPButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var qualityLabel: String {
        let q = model.exportOptions.quality
        return q >= 95 ? "Maximum" : q >= 85 ? "High" : q >= 70 ? "Medium" : "Small file"
    }

    private var outputDescription: String {
        let s = model.outputSize
        guard s.width > 0 else { return "" }
        var w = s.width, h = s.height
        if let edge = model.exportOptions.longEdge {
            let scale = min(1, CGFloat(edge) / max(w, h))
            w = floor(w * scale); h = floor(h * scale)
        }
        return "\(Int(w)) × \(Int(h)) px"
    }

    @ViewBuilder
    private func row<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.rpCharcoal)
                .frame(width: 80, alignment: .trailing)
            content()
        }
    }

    private func chooseDestination() {
        error = nil
        let panel = NSSavePanel()
        panel.allowedContentTypes = [model.exportOptions.format.type]
        panel.nameFieldStringValue = model.suggestedExportName()
        if let dir = model.lastExportURL?.deletingLastPathComponent() ?? model.fileURL?.deletingLastPathComponent() {
            panel.directoryURL = dir
        }
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.export(to: url) { result in
            switch result {
            case .success(let u): done = u
            case .failure(let e): error = e.localizedDescription
            }
        }
    }
}
