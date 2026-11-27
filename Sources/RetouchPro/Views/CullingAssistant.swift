import AppKit
import SwiftUI

/// Drives the Culling Assistant: pick photos → analyze → review categories → create albums.
final class CullingSession: ObservableObject {
    enum Step { case setup, analyzing, review }
    enum IssueHandling: String, CaseIterable, Identifiable {
        case tag = "Tag them, keep them in their category"
        case separate = "Move them into a “Needs Review” album"
        var id: String { rawValue }
    }

    @Published var step: Step = .setup
    @Published var photoIDs: [UUID] = []
    @Published var sourceName = ""
    @Published var shootType: ShootType = .wedding
    @Published var shootName = ""
    @Published var strictness = 1
    @Published var checks: Set<PhotoIssue> = Set(PhotoIssue.allCases)
    @Published var issueHandling: IssueHandling = .tag
    @Published var pickBest = true
    @Published var rejectProblems = false

    @Published var progress = 0
    @Published var categories: [CullingCategories.Category] = []
    @Published var analyses: [UUID: PhotoAnalysis] = [:]
    @Published var selectedCategory: UUID?
    @Published var showingIssuesOnly = false
    @Published var selection: Set<UUID> = []

    private var cancelled = false

    init() {
        let lib = Library.shared
        if !lib.gridSelection.isEmpty, lib.gridSelection.count > 1 {
            photoIDs = lib.visiblePhotos().map(\.id).filter(lib.gridSelection.contains)
            sourceName = "\(photoIDs.count) selected photos"
        } else {
            photoIDs = lib.visiblePhotos().map(\.id)
            sourceName = lib.title(for: lib.selection)
        }
        shootName = defaultName()
    }

    func defaultName() -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        return "\(shootType.rawValue) – \(f.string(from: Date()))"
    }

    func importFolder() {
        let ids = Library.shared.presentImportPanel(intoAlbum: nil)
        guard !ids.isEmpty else { return }
        photoIDs = ids
        sourceName = "\(ids.count) imported photos"
    }

    // MARK: Analysis

    func start() {
        guard !photoIDs.isEmpty else { return }
        step = .analyzing
        progress = 0
        cancelled = false
        let lib = Library.shared
        let jobs: [(UUID, URL)] = photoIDs.compactMap { id in
            guard let p = lib.photo(id), let url = lib.url(for: p) else { return nil }
            return (id, url)
        }
        let type = shootType
        let sensitivity = CullingEngine.Sensitivity.strictness(strictness)
        let checks = self.checks
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var results = [PhotoAnalysis?](repeating: nil, count: jobs.count)
            let lock = NSLock()
            var done = 0
            DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
                guard let self, !self.cancelled else { return }
                let a = CullingEngine.analyze(id: jobs[i].0, url: jobs[i].1)
                lock.lock()
                results[i] = a
                done += 1
                let d = done
                lock.unlock()
                if d % 3 == 0 || d == jobs.count { DispatchQueue.main.async { self.progress = d } }
            }
            guard let self, !self.cancelled else { return }
            var all = results.compactMap { $0 }
            CullingEngine.finish(&all, sensitivity: sensitivity)
            for i in all.indices { all[i].issues = all[i].issues.intersection(checks) }
            let cats = CullingCategories.categorize(all, type: type)
            DispatchQueue.main.async {
                self.analyses = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
                self.categories = cats
                self.selectedCategory = cats.first?.id
                self.step = .review
            }
        }
    }

    func cancel() {
        cancelled = true
        step = .setup
    }

    // MARK: Review

    var problemIDs: [UUID] {
        categories.flatMap(\.photoIDs).filter { (analyses[$0]?.issues ?? []).contains { $0.isDefect } }
    }
    var similarCount: Int { analyses.values.filter { $0.issues.contains(.similar) }.count }

    func count(_ issue: PhotoIssue) -> Int { analyses.values.filter { $0.issues.contains(issue) }.count }

    var visibleIDs: [UUID] {
        if showingIssuesOnly { return problemIDs }
        return categories.first { $0.id == selectedCategory }?.photoIDs ?? []
    }

    func rename(_ id: UUID, _ name: String) {
        guard let i = categories.firstIndex(where: { $0.id == id }) else { return }
        categories[i].name = name
    }

    func move(_ ids: [UUID], to target: UUID) {
        for i in categories.indices { categories[i].photoIDs.removeAll { ids.contains($0) } }
        if let t = categories.firstIndex(where: { $0.id == target }) { categories[t].photoIDs.append(contentsOf: ids) }
        categories.removeAll { $0.photoIDs.isEmpty && $0.id != target }
        selection = []
    }

    func addCategory() {
        let c = CullingCategories.Category(key: "custom-\(UUID().uuidString)", name: "New Category", photoIDs: [])
        categories.append(c)
        selectedCategory = c.id
    }

    func deleteCategory(_ id: UUID) {
        guard let i = categories.firstIndex(where: { $0.id == id }) else { return }
        let ids = categories[i].photoIDs
        categories.remove(at: i)
        if !ids.isEmpty {
            if let other = categories.firstIndex(where: { $0.key == CullingCategories.otherKey }) {
                categories[other].photoIDs.append(contentsOf: ids)
            } else {
                categories.append(.init(key: CullingCategories.otherKey, name: "Other", photoIDs: ids))
            }
        }
        selectedCategory = categories.first?.id
    }

    func clearIssues(_ ids: [UUID]) {
        for id in ids { analyses[id]?.issues = [] }
    }

    // MARK: Apply

    /// Creates a folder with one album per category, tags problems and (optionally) flags photos.
    func apply() -> UUID {
        let lib = Library.shared
        let folder = lib.createFolder(named: shootName.trimmingCharacters(in: .whitespaces).isEmpty ? defaultName() : shootName)
        let problems = Set(problemIDs)
        for c in categories where !c.photoIDs.isEmpty {
            let ids = issueHandling == .separate ? c.photoIDs.filter { !problems.contains($0) } : c.photoIDs
            if !ids.isEmpty { lib.createAlbum(named: c.name, inFolder: folder, photoIDs: ids) }
        }
        if issueHandling == .separate, !problems.isEmpty {
            let ordered = categories.flatMap(\.photoIDs).filter(problems.contains)
            lib.createAlbum(named: "Needs Review", inFolder: folder, photoIDs: ordered)
        }
        lib.setIssues(analyses.mapValues { Array($0.issues).sorted { $0.rawValue < $1.rawValue } })
        if pickBest {
            let keepers = analyses.values.filter { $0.issues.isEmpty }.map(\.id)
            lib.setFlag(.pick, for: keepers)
        }
        if rejectProblems {
            lib.setFlag(.reject, for: Array(problems))
        }
        lib.selection = .folder(folder)
        return folder
    }
}

// MARK: - View

struct CullingAssistantView: View {
    @StateObject private var session = CullingSession()
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.rpMist).frame(height: 1)
            switch session.step {
            case .setup: SetupStep(session: session)
            case .analyzing: AnalyzingStep(session: session)
            case .review: ReviewStep(session: session)
            }
            Rectangle().fill(Color.rpMist).frame(height: 1)
            footer
        }
        .frame(width: 980, height: 680)
        .background(Color.rpCard)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.stars").font(.system(size: 18))
            VStack(alignment: .leading, spacing: 2) {
                Text("Culling Assistant").font(.system(size: 16, weight: .semibold))
                Text(subtitle).font(.system(size: 11)).foregroundColor(.rpSlate)
            }
            Spacer()
            HStack(spacing: 6) {
                stepDot("Choose", active: session.step == .setup)
                stepDot("Analyze", active: session.step == .analyzing)
                stepDot("Review", active: session.step == .review)
            }
        }
        .foregroundColor(.rpInk)
        .padding(.horizontal, 20)
        .frame(height: 58)
    }

    private var subtitle: String {
        switch session.step {
        case .setup: return "Sorts a shoot into categories and finds closed eyes, talking, blur and duplicates — all on your Mac."
        case .analyzing: return "Looking at every photo…"
        case .review: return "Rename categories, move photos, then create the albums."
        }
    }

    private func stepDot(_ title: String, active: Bool) -> some View {
        Text(title)
            .font(.system(size: 11, weight: active ? .semibold : .regular))
            .foregroundColor(active ? .white : .rpSlate)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(active ? Color.rpAccent : Color.rpMist))
    }

    private var footer: some View {
        HStack {
            if session.step == .review {
                Text(summary).font(.system(size: 11)).foregroundColor(.rpSlate)
            }
            Spacer()
            Button(session.step == .analyzing ? "Stop" : "Cancel") {
                if session.step == .analyzing { session.cancel() } else { isPresented = false }
            }
            .buttonStyle(RPButtonStyle())
            .keyboardShortcut(.cancelAction)
            switch session.step {
            case .setup:
                Button {
                    session.start()
                } label: {
                    Label("Start Culling \(session.photoIDs.count) Photos", systemImage: "wand.and.stars")
                }
                .buttonStyle(RPButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(session.photoIDs.isEmpty)
            case .analyzing:
                EmptyView()
            case .review:
                Button("Back") { session.step = .setup }
                    .buttonStyle(RPButtonStyle())
                Button {
                    _ = session.apply()
                    EditorModel.shared.mode = .library
                    isPresented = false
                } label: {
                    Label("Create Albums", systemImage: "folder.badge.plus")
                }
                .buttonStyle(RPButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
    }

    private var summary: String {
        let total = session.categories.reduce(0) { $0 + $1.photoIDs.count }
        return "\(total) photos · \(session.categories.count) categories · \(session.problemIDs.count) with problems · \(session.similarCount) similar shots"
    }
}

private struct SetupStep: View {
    @ObservedObject var session: CullingSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                group("Photos") {
                    HStack(spacing: 12) {
                        Image(systemName: "photo.stack").font(.system(size: 22)).foregroundColor(.rpCharcoal)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.sourceName).font(.system(size: 13, weight: .semibold))
                            Text("\(session.photoIDs.count) photos").font(.system(size: 11)).foregroundColor(.rpSlate)
                        }
                        Spacer()
                        Button {
                            session.importFolder()
                        } label: {
                            Label("Import a Shoot Folder…", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(RPButtonStyle())
                    }
                    Text("Tip: select photos in the library first to cull just those, or open an album.")
                        .font(.system(size: 11)).foregroundColor(.rpSlate)
                }

                group("What kind of shoot?") {
                    HStack(spacing: 8) {
                        ForEach(ShootType.allCases) { type in
                            Button {
                                let wasDefault = session.shootName == session.defaultName()
                                session.shootType = type
                                if wasDefault { session.shootName = session.defaultName() }
                            } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: type.icon).font(.system(size: 18))
                                    Text(type.rawValue).font(.system(size: 11, weight: .medium))
                                }
                                .foregroundColor(session.shootType == type ? .white : .rpCharcoal)
                                .frame(maxWidth: .infinity)
                                .frame(height: 62)
                                .background(RoundedRectangle(cornerRadius: 9).fill(session.shootType == type ? Color.rpAccent : Color.rpPaper))
                                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.rpMist))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Text(categoryPreview)
                        .font(.system(size: 11)).foregroundColor(.rpSlate)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text("Folder name").font(.system(size: 12)).frame(width: 90, alignment: .leading)
                        TextField("Shoot name", text: $session.shootName).textFieldStyle(.roundedBorder)
                    }
                }

                group("Look for problems") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                        ForEach(PhotoIssue.allCases) { issue in
                            Toggle(isOn: Binding(
                                get: { session.checks.contains(issue) },
                                set: { on in if on { session.checks.insert(issue) } else { session.checks.remove(issue) } })) {
                                Label(issue.rawValue, systemImage: issue.icon).font(.system(size: 12))
                            }
                        }
                    }
                    HStack {
                        Text("Strictness").font(.system(size: 12)).frame(width: 90, alignment: .leading)
                        Picker("", selection: $session.strictness) {
                            Text("Relaxed").tag(0)
                            Text("Normal").tag(1)
                            Text("Strict").tag(2)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 260)
                    }
                    HStack(alignment: .top) {
                        Text("Problem photos").font(.system(size: 12)).frame(width: 90, alignment: .leading)
                        Picker("", selection: $session.issueHandling) {
                            ForEach(CullingSession.IssueHandling.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                    }
                    Toggle("Flag the keepers as Picks (sharp, eyes open, best of each similar series)", isOn: $session.pickBest)
                        .font(.system(size: 12))
                    Toggle("Flag photos with problems as Rejected", isOn: $session.rejectProblems)
                        .font(.system(size: 12))
                }
            }
            .padding(24)
            .foregroundColor(.rpInk)
        }
    }

    private var categoryPreview: String {
        let names = CullingCategories.rules(for: session.shootType).map(\.name)
        if names.isEmpty { return "Photos are grouped by moment (time and look), and each group is named after what's in it." }
        return "Suggested categories: " + names.joined(separator: " · ") + ". You can rename, add or merge them afterwards."
    }

    private func group<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold)).tracking(0.6)
                .foregroundColor(.rpSlate)
            content()
        }
    }
}

private struct AnalyzingStep: View {
    @ObservedObject var session: CullingSession

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "wand.and.stars").font(.system(size: 40, weight: .light)).foregroundColor(.rpCharcoal)
            Text("Looking at photo \(min(session.progress + 1, session.photoIDs.count)) of \(session.photoIDs.count)")
                .font(.system(size: 15, weight: .semibold)).foregroundColor(.rpInk)
            ProgressView(value: Double(session.progress), total: Double(max(1, session.photoIDs.count)))
                .frame(width: 420)
            Text("Checking faces, eyes, focus and exposure, recognizing scenes, and grouping moments. Nothing leaves your Mac.")
                .font(.system(size: 11)).foregroundColor(.rpSlate)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ReviewStep: View {
    @ObservedObject var session: CullingSession
    @ObservedObject private var library = Library.shared

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 270)
            Rectangle().fill(Color.rpMist).frame(width: 1)
            grid
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("CATEGORIES").font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundColor(.rpSlate)
                    .padding(.horizontal, 8).padding(.bottom, 2)
                ForEach(session.categories) { cat in
                    CategoryRow(session: session, category: cat)
                }
                Button {
                    session.addCategory()
                } label: {
                    Label("Add Category", systemImage: "plus").font(.system(size: 11.5))
                }
                .buttonStyle(.plain)
                .foregroundColor(.rpSlate)
                .padding(.horizontal, 8).padding(.vertical, 4)

                Text("PROBLEMS FOUND").font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundColor(.rpSlate)
                    .padding(.horizontal, 8).padding(.top, 14)
                Button {
                    session.showingIssuesOnly = true
                    session.selection = []
                } label: {
                    HStack {
                        Image(systemName: "exclamationmark.triangle").frame(width: 18)
                        Text("Needs Review")
                        Spacer()
                        Text("\(session.problemIDs.count)").font(.system(size: 11).monospacedDigit())
                    }
                    .font(.system(size: 12.5, weight: session.showingIssuesOnly ? .semibold : .regular))
                    .foregroundColor(session.showingIssuesOnly ? .white : .rpInk)
                    .padding(.horizontal, 8).frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 7).fill(session.showingIssuesOnly ? Color.rpAccent : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                ForEach(PhotoIssue.allCases) { issue in
                    let n = session.count(issue)
                    if n > 0 {
                        HStack {
                            Image(systemName: issue.icon).frame(width: 18)
                            Text(issue.rawValue)
                            Spacer()
                            Text("\(n)").font(.system(size: 11).monospacedDigit())
                        }
                        .font(.system(size: 11.5))
                        .foregroundColor(.rpSlate)
                        .padding(.horizontal, 8).padding(.leading, 12)
                    }
                }
            }
            .padding(12)
        }
        .background(Color.rpPaper)
    }

    private var grid: some View {
        let ids = session.visibleIDs
        let title = session.showingIssuesOnly ? "Needs Review"
            : session.categories.first { $0.id == session.selectedCategory }?.name ?? ""
        return VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundColor(.rpInk)
                    Text(session.selection.isEmpty ? "\(ids.count) photos · click to select, ⌘-click for more"
                                                   : "\(session.selection.count) selected")
                        .font(.system(size: 11)).foregroundColor(.rpSlate)
                }
                Spacer()
                if !session.selection.isEmpty {
                    Menu {
                        ForEach(session.categories) { c in
                            Button(c.name) { session.move(Array(session.selection), to: c.id) }
                        }
                    } label: {
                        Label("Move to", systemImage: "arrow.right.square")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Button("Not a Problem") {
                        session.clearIssues(Array(session.selection))
                        session.selection = []
                    }
                    .buttonStyle(RPButtonStyle())
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 10)], spacing: 10) {
                    ForEach(ids, id: \.self) { id in
                        if let photo = library.photo(id) {
                            CullCell(photo: photo, analysis: session.analyses[id], selected: session.selection.contains(id))
                                .onTapGesture {
                                    if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                                        if session.selection.contains(id) { session.selection.remove(id) } else { session.selection.insert(id) }
                                    } else {
                                        session.selection = [id]
                                    }
                                }
                                .contextMenu {
                                    Menu("Move to") {
                                        ForEach(session.categories) { c in
                                            Button(c.name) {
                                                let ids = session.selection.contains(id) ? Array(session.selection) : [id]
                                                session.move(ids, to: c.id)
                                            }
                                        }
                                    }
                                    Button("Not a Problem") { session.clearIssues([id]) }
                                }
                        }
                    }
                }
                .padding(14)
            }
            .background(Color.rpMist)
        }
    }
}

private struct CategoryRow: View {
    @ObservedObject var session: CullingSession
    let category: CullingCategories.Category
    @State private var name = ""
    @State private var hover = false

    var selected: Bool { !session.showingIssuesOnly && session.selectedCategory == category.id }

    var body: some View {
        HStack(spacing: 6) {
            TextField("Category name", text: $name, onCommit: { session.rename(category.id, name) })
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                .foregroundColor(selected ? .white : .rpInk)
                .onChange(of: name) { session.rename(category.id, $0) }
            Text("\(category.photoIDs.count)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(selected ? .white.opacity(0.8) : .rpSlate)
            if hover {
                Button {
                    session.deleteCategory(category.id)
                } label: {
                    Image(systemName: "trash").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundColor(selected ? .white : .rpSlate)
                .help("Remove category (its photos move to Other)")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.rpAccent : (hover ? Color.rpMist : .clear)))
        .contentShape(Rectangle())
        .onTapGesture {
            session.showingIssuesOnly = false
            session.selectedCategory = category.id
            session.selection = []
        }
        .onHover { hover = $0 }
        .onAppear { name = category.name }
        .help("Click the name to rename it")
    }
}

private struct CullCell: View {
    let photo: LibraryPhoto
    let analysis: PhotoAnalysis?
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PhotoCell(photo: photo, selected: selected, size: 160, showName: false)
            HStack(spacing: 4) {
                if let a = analysis {
                    if a.issues.isEmpty {
                        Label("Keeper", systemImage: "star.fill")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundColor(.rpCharcoal)
                    }
                    ForEach(Array(a.issues).sorted { $0.rawValue < $1.rawValue }) { issue in
                        Image(systemName: issue.icon)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundColor(issue.isDefect ? .orange : .rpSlate)
                            .help(issue.rawValue)
                    }
                    Spacer()
                    if a.faceCount > 0 {
                        Label("\(a.faceCount)", systemImage: "person.fill")
                            .font(.system(size: 9.5))
                            .foregroundColor(.rpSlate)
                    }
                }
            }
            .frame(height: 14)
        }
    }
}
