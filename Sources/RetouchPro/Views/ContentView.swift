import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: EditorModel
    @State private var showExport = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            TopBar(showExport: $showExport)
            Rectangle().fill(Color.rpMist).frame(height: 1)
            HStack(spacing: 0) {
                ToolRail()
                Rectangle().fill(Color.rpMist).frame(width: 1)
                ZStack {
                    Color.rpMist
                    if model.hasImage {
                        CanvasView()
                    } else if !model.isLoading {
                        EmptyStateView(targeted: dropTargeted)
                    }
                    if model.isLoading {
                        LoadingBadge()
                    }
                }
                if model.hasImage {
                    Rectangle().fill(Color.rpMist).frame(width: 1)
                    InspectorView()
                        .frame(width: 300)
                }
            }
        }
        .background(Color.rpPaper)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    DispatchQueue.main.async { model.open(url: url) }
                }
            }
            return true
        }
        .sheet(isPresented: $showExport) {
            ExportSheet(isPresented: $showExport)
                .environmentObject(model)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showExport)) { _ in
            if model.hasImage { showExport = true }
        }
        .alert("Couldn’t open photo", isPresented: Binding(
            get: { model.loadError != nil },
            set: { if !$0 { model.loadError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.loadError ?? "")
        }
    }
}

struct LoadingBadge: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.regular)
            Text("Opening photo…")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.rpCharcoal)
        }
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.rpPaper))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    }
}

struct EmptyStateView: View {
    @EnvironmentObject var model: EditorModel
    var targeted: Bool

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(Color.rpPaper).frame(width: 108, height: 108)
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 44, weight: .light))
                    .foregroundColor(.rpCharcoal)
            }
            VStack(spacing: 6) {
                Text("Drop a photo here to start editing")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.rpInk)
                Text("JPEG, HEIC, PNG, TIFF and camera RAW (CR2, CR3, NEF, ARW, DNG, RAF…)")
                    .font(.system(size: 12))
                    .foregroundColor(.rpSlate)
            }
            Button {
                model.presentOpenPanel()
            } label: {
                Label("Open Photo…", systemImage: "folder")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
            }
            .buttonStyle(RPButtonStyle(kind: .primary))
            .controlSize(.large)

            Text("Tip: press ⌘O any time to open another photo.")
                .font(.system(size: 11))
                .foregroundColor(.rpSlate)
                .padding(.top, 4)
        }
        .padding(56)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(targeted ? Color.white : Color.rpPaper.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(targeted ? Color.rpCharcoal : Color.rpSilver,
                              style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
        )
        .padding(40)
        .animation(.easeInOut(duration: 0.15), value: targeted)
    }
}
