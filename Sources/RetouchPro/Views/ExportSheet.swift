import AppKit
import SwiftUI

struct ExportSheet: View {
    @EnvironmentObject var model: EditorModel
    @Binding var isPresented: Bool
    @State private var error: String?
    @State private var done: URL?
    /// Batch export: the library photos to export (empty = the open photo).
    var batchIDs: [UUID] = []
    @State private var batchProgress: Int?
    @State private var batchResult: (written: Int, failed: [String], folder: URL)?
    private var isBatch: Bool { !batchIDs.isEmpty }

    private let sizes: [(String, Int?)] = [
        ("Full size", nil), ("4096 px", 4096), ("2048 px (web)", 2048), ("1080 px (social)", 1080),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 18))
                Text(isBatch ? "Export \(batchIDs.count) Photos" : "Export Photo")
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundColor(.rpInk)

            if let result = batchResult {
                batchDoneView(result)
            } else if let progress = batchProgress {
                batchProgressView(progress)
            } else if let done {
                successView(done)
            } else {
                form
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(Color.rpPaper)
        .onAppear { model.loadExportDefaults() }
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
                    RPSlider(title: qualityLabel, value: $model.exportOptions.quality, range: 40...100, defaultValue: 90,
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
                    RPSlider(title: "Size", value: $model.exportOptions.watermarkSize, range: 1...10, defaultValue: 3,
                             format: { String(format: "%.1f%%", $0) }, onCommit: {})
                    RPSlider(title: "Opacity", value: $model.exportOptions.watermarkOpacity, range: 10...100, defaultValue: 70,
                             format: { "\(Int($0.rounded()))%" }, onCommit: {})
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.rpCard))
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
                    if isBatch { chooseFolder() } else { chooseDestination() }
                } label: {
                    if isBatch {
                        Text("Choose Folder & Export…")
                    } else if model.isExporting {
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

    private func batchProgressView(_ n: Int) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Exporting photo \(min(n + 1, batchIDs.count)) of \(batchIDs.count)…")
                .font(.system(size: 13, weight: .medium)).foregroundColor(.rpInk)
            ProgressView(value: Double(n), total: Double(batchIDs.count))
            Text("Each photo is rendered at full quality with its own edits. RAW files take a second or two each.")
                .font(.system(size: 11)).foregroundColor(.rpSlate)
            HStack {
                Spacer()
                Button("Stop") { model.cancelBatchExport() }
                    .buttonStyle(RPButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func batchDoneView(_ r: (written: Int, failed: [String], folder: URL)) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: r.failed.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(r.failed.isEmpty ? .rpCharcoal : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Exported \(r.written) photo\(r.written == 1 ? "" : "s")")
                        .font(.system(size: 14, weight: .semibold)).foregroundColor(.rpInk)
                    Text(r.folder.path).font(.system(size: 11)).foregroundColor(.rpSlate).lineLimit(1).truncationMode(.middle)
                    if !r.failed.isEmpty {
                        Text("Couldn’t export: \(r.failed.prefix(5).joined(separator: ", "))\(r.failed.count > 5 ? "…" : "")")
                            .font(.system(size: 11)).foregroundColor(.orange)
                    }
                }
            }
            HStack {
                Button("Show in Finder") { NSWorkspace.shared.open(r.folder) }
                    .buttonStyle(RPButtonStyle())
                Spacer()
                Button("Done") { isPresented = false }
                    .buttonStyle(RPButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder for the \(batchIDs.count) exported photos"
        if let dir = model.lastExportURL?.deletingLastPathComponent() { panel.directoryURL = dir }
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        batchProgress = 0
        model.exportBatch(batchIDs, to: folder, progress: { batchProgress = $0 }) { written, failed in
            batchProgress = nil
            batchResult = (written, failed, folder)
            model.lastExportURL = folder.appendingPathComponent("x")
        }
    }

    private var outputDescription: String {
        if isBatch { return "\(batchIDs.count) photos · each with its own edits" }
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
