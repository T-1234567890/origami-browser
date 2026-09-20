import AppKit
import Observation
import Darwin

extension MigrationBrowser {
    var bundleID: String {
        switch self {
        case .safari: "com.apple.Safari"
        case .chrome: "com.google.Chrome"
        case .arc: "company.thebrowser.Browser"
        case .firefox: "org.mozilla.firefox"
        case .brave: "com.brave.Browser"
        case .edge: "com.microsoft.edgemac"
        case .zen: "app.zen-browser.zen"
        case .vivaldi: "com.vivaldi.Vivaldi"
        case .opera: "com.operasoftware.Opera"
        case .orion: "com.kagi.kagimacOS"
        }
    }
    /// Standard locations only; never crawl the user's home directory.
    var dataLocations: [String] {
        switch self {
        case .safari: ["Library/Safari", "Library/Containers/com.apple.Safari/Data/Library/Safari"]
        case .chrome: ["Library/Application Support/Google/Chrome"]
        case .arc: ["Library/Application Support/Arc/User Data"]
        case .firefox: ["Library/Application Support/Firefox/Profiles"]
        case .brave: ["Library/Application Support/BraveSoftware/Brave-Browser"]
        case .edge: ["Library/Application Support/Microsoft Edge"]
        case .zen: ["Library/Application Support/zen/Profiles"]
        case .vivaldi: ["Library/Application Support/Vivaldi"]
        case .opera: ["Library/Application Support/com.operasoftware.Opera"]
        case .orion: ["Library/Application Support/Orion"]
        }
    }
}
struct MigrationSource: Identifiable {
    var browser: MigrationBrowser
    var roots: [URL]
    var applicationURL: URL?
    var id: MigrationBrowser { browser }
}
enum MigrationDiscovery {
    /// Injectable metadata probes keep tests independent of installed apps and personal data.
    static func sources(home: URL, application: (String) -> URL?, exists: (URL) -> Bool) -> [MigrationSource] {
        MigrationBrowser.allCases.compactMap { browser in
            let app = application(browser.bundleID)
            let candidates = browser.dataLocations.map { home.appending(path: $0) }
            let found = candidates.filter(exists)
            guard app != nil || !found.isEmpty else { return nil }
            // An installed app may have a privacy-protected directory invisible to fileExists.
            return MigrationSource(browser: browser, roots: app != nil ? candidates : found, applicationURL: app)
        }
    }
    /// Foundation's current-user home is redirected inside an App Sandbox container.
    /// Account metadata gives the real home; this does not grant access to its contents.
    static func accountHome() -> URL? {
        var entry = passwd(), result: UnsafeMutablePointer<passwd>?
        var bytes = [CChar](repeating: 0, count: 16_384)
        return bytes.withUnsafeMutableBufferPointer { buffer in
            guard getpwuid_r(getuid(), &entry, buffer.baseAddress, buffer.count, &result) == 0,
                  result != nil, let directory = entry.pw_dir else { return nil }
            let path = String(cString: directory)
            guard path.hasPrefix("/"), path != "/" else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
    }
    @MainActor static func installed() -> [MigrationSource] {
        guard let home = accountHome() else { return [] }
        return sources(home: home,
                application: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
                exists: { FileManager.default.fileExists(atPath: $0.path) })
    }
}

@MainActor @Observable final class MigrationFlow {
    var sources: [MigrationSource] = []
    var source: MigrationSource?
    var profiles: [MigrationProfile] = []
    var selected: UUID?
    var selection = MigrationSelection()
    var replace = false
    var busy = false
    var error: String?
    var needsAccess = false
    private var accessRoot: URL?
    var completed = false
    private var discovered = false
    private var requestID = UUID()
    var profile: MigrationProfile? { profiles.first { $0.id == selected } }
    var canImport: Bool {
        guard let p = profile, !busy else { return false }
        return (selection.bookmarks && p.bookmarks != nil) || (selection.history && p.history != nil) || (selection.tabs && p.tabs != nil)
    }
    func discover() {
        guard !discovered else { return }
        discovered = true; sources = MigrationDiscovery.installed()
    }
    func reset() {
        requestID = UUID(); busy = false; source = nil; profiles = []; selected = nil
        error = nil; needsAccess = false; accessRoot = nil; completed = false; selection = MigrationSelection(); replace = false
    }
    func choose(_ value: MigrationSource) {
        reset(); source = value
        // Do not quit another app or read a live, changing database without the user acting.
        if !NSRunningApplication.runningApplications(withBundleIdentifier: value.browser.bundleID).isEmpty {
            error = L10n.format("Quit %@ to bring over your latest data, then try again.", value.browser.rawValue)
            return
        }
        read(value.roots, browser: value.browser)
    }
    func grantAccess() {
        guard let source, let root = accessRoot ?? source.roots.first else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.directoryURL = root
        panel.prompt = L10n.string("Allow Access")
        panel.message = L10n.format("Allow Origami to read %@’s browsing data. The browser’s folder is already selected.", source.browser.rawValue)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self, self.source?.id == source.id else { return }
            // This is an access grant for the detected browser, not an arbitrary-file importer.
            guard source.roots.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) else {
                self.error = L10n.string("Access was not granted to the browser’s data. Try Allow Access again."); return
            }
            self.read([url], browser: source.browser, scoped: true)
        }
    }
    private func read(_ roots: [URL], browser: MigrationBrowser, scoped: Bool = false) {
        busy = true; error = nil; needsAccess = false
        let id = UUID(); requestID = id
        Task {
            do {
                let results = try await Task.detached(priority: .userInitiated) {
                    try MigrationAccess.readRoots(roots) { root in
                        let access = scoped && root.startAccessingSecurityScopedResource()
                        defer { if access { root.stopAccessingSecurityScopedResource() } }
                        _ = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                        return try MigrationReader.read(root, browser: browser)
                    }
                }.value
                guard requestID == id else { return }
                profiles = results; selected = results.first?.id
            } catch {
                guard requestID == id else { return }
                needsAccess = MigrationAccess.denied(error)
                accessRoot = (error as? MigrationAccessRequired)?.root
                self.error = needsAccess ? L10n.format("Allow Origami to read %@’s data to continue.", browser.rawValue) :
                    L10n.format("No compatible browsing data was found for %@. You can try again or choose another browser.", browser.rawValue)
            }
            if requestID == id { busy = false }
        }
    }
}
