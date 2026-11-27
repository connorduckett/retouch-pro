import AppKit
import Foundation

/// Checks GitHub Releases for a newer Retouch Pro and installs it in place.
final class Updater: ObservableObject {
    static let shared = Updater()
    static let repository = "connorduckett/retouch-pro"
    static let autoCheckKey = "autoCheckForUpdates"
    static let lastCheckKey = "lastUpdateCheck"

    struct Release: Equatable {
        var version: String
        var notes: String
        var pageURL: URL
        var zipURL: URL?
    }

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading
        case installing
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var lastChecked: Date? = UserDefaults.standard.object(forKey: lastCheckKey) as? Date

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    var latestPageURL: URL { URL(string: "https://github.com/\(Self.repository)/releases/latest")! }

    // MARK: Checking

    /// Checks automatically at most once a day, if the user hasn't turned it off.
    /// Removes leftover download folders from earlier updates.
    func cleanUpOldDownloads() {
        let tmp = FileManager.default.temporaryDirectory
        let items = (try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? []
        for item in items where item.lastPathComponent.hasPrefix("RetouchProUpdate-") {
            try? FileManager.default.removeItem(at: item)
        }
    }

    func checkOnLaunchIfNeeded() {
        let d = UserDefaults.standard
        if d.object(forKey: Self.autoCheckKey) != nil && !d.bool(forKey: Self.autoCheckKey) { return }
        if let last = lastChecked, Date().timeIntervalSince(last) < 60 * 60 * 20 { return }
        check(userInitiated: false)
    }

    /// `userInitiated` shows alerts for every outcome; otherwise only a found update is announced.
    func check(userInitiated: Bool, alert: Bool = true) {
        if status == .checking || status == .downloading || status == .installing { return }
        status = .checking
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("RetouchPro-Updater", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Result<Release, Error> = Result {
                if let error { throw error }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data,
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String,
                      let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else {
                    throw UpdateError.message("GitHub didn't return release information. Try again later.")
                }
                let assets = json["assets"] as? [[String: Any]] ?? []
                let zip = assets
                    .first { ($0["name"] as? String)?.lowercased().hasSuffix(".zip") == true }
                    .flatMap { $0["browser_download_url"] as? String }
                    .flatMap(URL.init(string:))
                return Release(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")),
                               notes: json["body"] as? String ?? "",
                               pageURL: page, zipURL: zip)
            }
            DispatchQueue.main.async {
                self.lastChecked = Date()
                UserDefaults.standard.set(self.lastChecked, forKey: Self.lastCheckKey)
                switch result {
                case .success(let release):
                    if Self.isNewer(release.version, than: self.currentVersion) {
                        self.status = .available(release)
                        if alert { self.presentAvailableAlert(release) }
                    } else {
                        self.status = .upToDate
                        if userInitiated && alert {
                            self.simpleAlert("You’re up to date",
                                             "Retouch Pro \(self.currentVersion) is the newest version.")
                        }
                    }
                case .failure(let e):
                    self.status = userInitiated ? .failed(Self.friendly(e)) : .idle
                    if userInitiated && alert { self.simpleAlert("Couldn’t check for updates", Self.friendly(e)) }
                }
            }
        }.resume()
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Installing

    func openReleasePage(_ release: Release? = nil) {
        NSWorkspace.shared.open(release?.pageURL ?? latestPageURL)
    }

    /// Downloads the new version, swaps it in for this copy of the app, and relaunches.
    func downloadAndInstall(_ release: Release) {
        guard let zipURL = release.zipURL, zipURL.host?.hasSuffix("github.com") == true else {
            openReleasePage(release)
            return
        }
        guard EditorModel.shared.confirmQuitForUpdate() else { return }
        status = .downloading

        URLSession.shared.downloadTask(with: zipURL) { tempURL, _, error in
            let result: Result<URL, Error> = Result {
                if let error { throw error }
                guard let tempURL else { throw UpdateError.message("The download didn't finish.") }
                return try self.unpack(tempURL)
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let newApp):
                    self.status = .installing
                    self.install(newApp, release: release)
                case .failure(let e):
                    self.status = .failed(Self.friendly(e))
                    self.simpleAlert("Update failed", Self.friendly(e))
                }
            }
        }.resume()
    }

    private func unpack(_ zip: URL) throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("RetouchProUpdate-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let archive = work.appendingPathComponent("update.zip")
        try fm.moveItem(at: zip, to: archive)

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, work.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw UpdateError.message("The update couldn't be unzipped.") }

        let items = try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
        guard let app = items.first(where: { $0.pathExtension == "app" }),
              let bundle = Bundle(url: app), bundle.bundleIdentifier == Bundle.main.bundleIdentifier ?? bundle.bundleIdentifier
        else { throw UpdateError.message("The download didn't contain Retouch Pro.") }
        return app
    }

    private func install(_ newApp: URL, release: Release) {
        let current = Bundle.main.bundleURL
        let parent = current.deletingLastPathComponent()
        let canReplace = current.pathExtension == "app"
            && !current.path.contains("/AppTranslocation/")
            && FileManager.default.isWritableFile(atPath: parent.path)

        guard canReplace else {
            // Can't replace this copy (e.g. running straight from Downloads): hand the new app to the user.
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            let dest = downloads.appendingPathComponent("Retouch Pro \(release.version).app")
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.moveItem(at: newApp, to: dest)
                status = .available(release)
                NSWorkspace.shared.activateFileViewerSelecting([dest])
                simpleAlert("Retouch Pro \(release.version) downloaded",
                            "It’s in your Downloads folder. Drag it into Applications to replace this version, then open it.")
            } catch {
                status = .failed(Self.friendly(error))
                openReleasePage(release)
            }
            return
        }

        // A tiny helper waits for this app to quit, swaps the bundles and opens the new version.
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf "$TARGET.old"
        mv "$TARGET" "$TARGET.old" && mv "$NEWAPP" "$TARGET" && rm -rf "$TARGET.old" || mv "$TARGET.old" "$TARGET"
        xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null
        open "$TARGET"
        rm -rf "$WORKDIR"
        """
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script]
        helper.environment = ["TARGET": current.path, "NEWAPP": newApp.path,
                              "WORKDIR": newApp.deletingLastPathComponent().path,
                              "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        do {
            try helper.run()
            EditorModel.shared.flushEdits()
            Library.shared.saveNow()
            // Close every window first: an open sheet or panel can make AppKit ignore terminate.
            for window in NSApp.windows { window.sheets.forEach { window.endSheet($0) } }
            NSApp.terminate(nil)
            // If something still blocked quitting, make sure everything is saved and exit anyway —
            // otherwise the installer would wait forever.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                EditorModel.shared.flushEdits()
                Library.shared.saveNow()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { exit(0) }
            }
        } catch {
            status = .failed(Self.friendly(error))
            simpleAlert("Update failed", Self.friendly(error))
        }
    }

    // MARK: Alerts

    private func presentAvailableAlert(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = "Retouch Pro \(release.version) is available"
        let notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.informativeText = "You have version \(currentVersion)."
            + (notes.isEmpty ? "" : "\n\n" + String(notes.prefix(600)))
        alert.addButton(withTitle: "Install and Restart")
        alert.addButton(withTitle: "View on GitHub")
        alert.addButton(withTitle: "Later")
        switch alert.runModal() {
        case .alertFirstButtonReturn: downloadAndInstall(release)
        case .alertSecondButtonReturn: openReleasePage(release)
        default: break
        }
    }

    private func simpleAlert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    enum UpdateError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let m) = self { return m }
            return nil
        }
    }

    private static func friendly(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return "Couldn’t reach GitHub. Check your internet connection and try again." }
        return error.localizedDescription
    }
}
