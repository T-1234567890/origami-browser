import AppKit
import UniformTypeIdentifiers

extension BrowserStore {
    func fileAction(_ method: String, tabID: UUID) async throws -> Any {
        guard let services, let window = nativeWindow ?? pages[tabID]?.webView.window else { throw RepositoryError.invalidInput }
        if method == "bookmarks.export" {
            let panel = NSSavePanel(); panel.allowedContentTypes = [.html]; panel.nameFieldStringValue = "Origami Bookmarks.html"
            guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return false }
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            try BookmarkHTMLService(services.bookmarks).exportHTML(profileID: session.profileID).write(to: url, options: .atomic)
            return true
        }
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
        panel.canChooseDirectories = method == "downloads.directory"; panel.canChooseFiles = method != "downloads.directory"
        if panel.canChooseFiles { panel.allowedContentTypes = [.html] }
        guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return false }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        if method == "downloads.directory" { preferences.downloadDirectoryBookmark = try url.bookmarkData(options: .withSecurityScope); return true }
        let count = try BookmarkHTMLService(services.bookmarks).importHTML(Data(contentsOf: url), profileID: session.profileID)
        bookmarkRevision += 1; return count
    }
}
