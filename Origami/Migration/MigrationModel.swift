import Foundation

enum MigrationBrowser: String, CaseIterable, Identifiable {
    case safari = "Safari", chrome = "Google Chrome", arc = "Arc", firefox = "Firefox", brave = "Brave", edge = "Microsoft Edge", zen = "Zen", vivaldi = "Vivaldi", opera = "Opera", orion = "Orion"
    var id: String { rawValue }
    var gecko: Bool { self == .firefox || self == .zen }
    var chromium: Bool { !gecko && self != .safari && self != .orion }

}
struct MigrationBookmark: Sendable {
    var title: String
    var url: URL?
    var children: [MigrationBookmark] = []
}
struct MigrationVisit: Sendable { var url: URL; var title: String; var date: Date }
struct MigrationTab: Sendable { var url: URL; var title: String; var pinned: Bool; var group: String? }
struct MigrationProfile: Identifiable, Sendable {
    var id = UUID()
    var name: String
    var bookmarks: [MigrationBookmark]?
    var history: [MigrationVisit]?
    var tabs: [MigrationTab]?
    var search: String?
    var notes: [String] = []
    var bookmarkCount: Int {
        func count(_ items: [MigrationBookmark]) -> Int { items.reduce(0) { $0 + ($1.url == nil ? count($1.children) : 1) } }
        return count(bookmarks ?? [])
    }
    var hasData: Bool { bookmarks != nil || history != nil || tabs != nil }
}
enum MigrationFailure: Error, LocalizedError {
    case invalid, tooLarge, unsupported, sharedDestination, destinationOpen
    var errorDescription: String? {
        switch self {
        case .invalid: "The selected data is malformed or unreadable. Quit the source browser and try an exported copy."
        case .tooLarge: "This import exceeds the supported size limit. Export a smaller set of data."
        case .unsupported: "No supported browser data was found. Choose a profile folder or an exported bookmarks HTML file."
        case .sharedDestination: "Choose a separate destination profile. This profile shares bookmarks or history with another profile."
        case .destinationOpen: "Close other windows for the destination profile before replacing its data."
        }
    }
}
enum MigrationInput {
    static func url(_ text: String?) -> URL? {
        guard let text, text.count <= 16384, let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased()), url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
    static func read(_ url: URL, limit: Int = 32_000_000) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw MigrationFailure.invalid }
        guard (values.fileSize ?? Int.max) <= limit else { throw MigrationFailure.tooLarge }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw MigrationFailure.tooLarge }
        return data
    }
    static func child(_ name: String, in root: URL) throws -> URL? {
        let url = root.appending(path: name)
        do { _ = try url.resourceValues(forKeys: [.isSymbolicLinkKey]) }
        catch {
            let value = error as NSError
            if value.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(value.code) { return nil }
            throw error
        }
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(base),
              try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw MigrationFailure.invalid }
        return url
    }
}
