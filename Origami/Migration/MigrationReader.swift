import Foundation
import GRDB

/// Explicit allowlist of source files. No passwords, cookies, extensions or downloads are opened.
enum MigrationReader {
    static func read(_ root: URL, browser: MigrationBrowser) throws -> [MigrationProfile] {
        if ["html", "htm"].contains(root.pathExtension.lowercased()) {
            return [MigrationProfile(name: browser.rawValue, bookmarks: try html(MigrationInput.read(root)), notes: ["Bookmarks export only. Other browser data is not included."])]
        }
        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw MigrationFailure.unsupported }
        let markers = browser.gecko ? ["places.sqlite"] : browser.chromium ? ["Bookmarks", "History", "Preferences"] : ["Bookmarks.plist", "History.db", "bookmarks.html"]
        func recognized(_ directory: URL) throws -> Bool { try markers.contains { try MigrationInput.child($0, in: directory) != nil } }
        var folders: [URL] = []
        if try recognized(root) { folders = [root] }
        else {
            let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard entries.count <= 500 else { throw MigrationFailure.tooLarge }
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let info = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if info.isDirectory == true, info.isSymbolicLink != true, try recognized(entry) { folders.append(entry) }
            }
        }
        guard !folders.isEmpty, folders.count <= 50 else { throw MigrationFailure.unsupported }
        var results: [MigrationProfile] = []
        var total = 0
        for folder in folders {
            let value: MigrationProfile
            do { value = try profile(folder, browser: browser) }
            catch MigrationFailure.unsupported { continue } // Internal/system profiles have no importable data.
            total += value.bookmarkCount + (value.history?.count ?? 0) + (value.tabs?.count ?? 0)
            guard total <= 200_000 else { throw MigrationFailure.tooLarge }
            results.append(value)
        }
        guard !results.isEmpty else { throw MigrationFailure.unsupported }
        return results
    }
    static func profile(_ folder: URL, browser: MigrationBrowser) throws -> MigrationProfile {
        var result = MigrationProfile(name: String(folder.lastPathComponent.prefix(70)))
        var accessError: Error?
        func part(_ title: String, _ work: () throws -> Void) {
            do { try work() } catch {
                if MigrationAccess.denied(error) { accessError = error }
                result.notes.append("\(title) could not be read; that category will not replace existing data.")
            }
        }
        if browser.chromium {
            part("Bookmarks") {
                if let file = try MigrationInput.child("Bookmarks", in: folder) {
                    let root = try JSONSerialization.jsonObject(with: MigrationInput.read(file)) as? [String: Any]
                    guard let roots = root?["roots"] as? [String: [String: Any]] else { throw MigrationFailure.invalid }
                    result.bookmarks = try roots.keys.sorted().map { try chromiumBookmark(roots[$0]!, depth: 0) }
                }
            }
            part("History") {
                if let file = try MigrationInput.child("History", in: folder) {
                    result.history = try visits(file, sql: "SELECT u.url,u.title,v.visit_time AS time FROM visits v JOIN urls u ON u.id=v.url ORDER BY v.visit_time DESC LIMIT 100001", scale: 1_000_000, offset: -11_644_473_600)
                }
            }
            part("Search preference") {
                if let file = try MigrationInput.child("Preferences", in: folder), let object = try JSONSerialization.jsonObject(with: MigrationInput.read(file, limit: 8_000_000)) as? [String: Any] {
                    let p = object["profile"] as? [String: Any]
                    if let name = p?["name"] as? String, !name.isEmpty { result.name = String(name.prefix(70)) }
                    let provider = object["default_search_provider"] as? [String: Any]
                    result.search = search(provider?["search_url"] as? String ?? provider?["name"] as? String)
                }
            }
            part("Previous session") { result.tabs = try ChromiumMigrationSession.read(folder) }
            if result.tabs != nil { result.notes.append("Standard unencrypted session tabs and pins are supported. Browser-specific tab groups and spaces are not transferred.") }
            if browser == .arc { result.notes.append("Arc spaces, favorites and sidebar folders are not inferred from proprietary sidebar data. Use a bookmarks export for those items.") }
        } else if browser.gecko {
            part("Bookmarks and history") {
                if let file = try MigrationInput.child("places.sqlite", in: folder) {
                    result.bookmarks = try geckoBookmarks(file)
                    result.history = try visits(file, sql: "SELECT p.url,p.title,v.visit_date AS time FROM moz_historyvisits v JOIN moz_places p ON p.id=v.place_id ORDER BY v.visit_date DESC LIMIT 100001", scale: 1_000_000, offset: 0)
                }
            }
            part("Previous session") {
                for name in ["sessionstore.jsonlz4", "sessionstore-backups/recovery.jsonlz4", "sessionstore-backups/previous.jsonlz4", "sessionstore.json"] {
                    if let file = try MigrationInput.child(name, in: folder) {
                        result.tabs = try GeckoMigrationSession.read(MigrationInput.read(file)); break
                    }
                }
            }
            part("Search preference") {
                if let file = try MigrationInput.child("search.json.mozlz4", in: folder) {
                    let data = try GeckoMigrationSession.decode(MigrationInput.read(file))
                    let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    let meta = root?["metaData"] as? [String: Any]
                    result.search = search(meta?["defaultEngineId"] as? String ?? meta?["current"] as? String)
                }
            }
            if browser == .zen { result.notes.append("Firefox-compatible session tabs are imported. Zen container identities and workspace isolation are not transferred.") }
        } else {
            part("Bookmarks") {
                if let file = try MigrationInput.child("Bookmarks.plist", in: folder),
                   let root = try PropertyListSerialization.propertyList(from: MigrationInput.read(file), format: nil) as? [String: Any] {
                    result.bookmarks = try safariBookmarks(root, depth: 0)
                } else if let file = try MigrationInput.child("bookmarks.html", in: folder) { result.bookmarks = try html(MigrationInput.read(file)) }
            }
            part("History") {
                if let file = try MigrationInput.child("History.db", in: folder) {
                    result.history = try visits(file, sql: "SELECT i.url,v.title,v.visit_time AS time FROM history_visits v JOIN history_items i ON i.id=v.history_item ORDER BY v.visit_time DESC LIMIT 100001", scale: 1, offset: 978_307_200)
                }
            }
            result.notes.append("Safari/Orion sessions, tab groups and search preferences are unavailable in this adapter. Import each source profile separately when exporting bookmarks.")
        }
        if result.bookmarks == nil { result.notes.append("Bookmarks unavailable.") }
        if result.history == nil { result.notes.append("History unavailable.") }
        if result.tabs == nil { result.notes.append("Open/pinned tabs and groups unavailable.") }
        if result.search == nil { result.notes.append("Search engine not available or not supported by Origami; your preference stays unchanged.") }
        if let accessError { throw accessError }
        guard result.hasData else { throw MigrationFailure.unsupported }
        return result
    }
    static func search(_ text: String?) -> String? {
        guard let text = text?.lowercased() else { return nil }
        for (needle, value) in [("duckduckgo", "duckDuckGo"), ("google", "google"), ("bing", "bing"), ("brave", "brave")] {
            if text.contains(needle) { return value }
        }
        return nil
    }
    static func database<T>(_ file: URL, _ body: (Database) throws -> T) throws -> T {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 1_000_000_000 else { throw MigrationFailure.tooLarge }
        // SQLite may create a shared-memory sidecar even for a read-only WAL reader.
        // Work from a temporary copy so the source browser's directory stays untouched.
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let snapshot = temporary.appending(path: "source.sqlite")
        try FileManager.default.copyItem(at: file, to: snapshot)
        if let wal = try MigrationInput.child(file.lastPathComponent + "-wal", in: file.deletingLastPathComponent()) {
            let info = try wal.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard info.isRegularFile == true, (info.fileSize ?? Int.max) <= 1_000_000_000 else { throw MigrationFailure.tooLarge }
            try FileManager.default.copyItem(at: wal, to: temporary.appending(path: "source.sqlite-wal"))
        }
        var config = Configuration(); config.readonly = true
        config.prepareDatabase { db in try db.execute(sql: "PRAGMA trusted_schema=OFF; PRAGMA query_only=ON") }
        let source = try DatabaseQueue(path: snapshot.path, configuration: config)
        return try source.read(body)
    }
    static func visits(_ file: URL, sql: String, scale: Double, offset: Double) throws -> [MigrationVisit] {
        try database(file) { db in
            let rows = try Row.fetchAll(db, sql: sql)
            guard rows.count <= 100_000 else { throw MigrationFailure.tooLarge }
            return rows.compactMap {
                guard let url = MigrationInput.url($0["url"]), let time: Double = $0["time"] else { return nil }
                let seconds = time / scale + offset
                guard seconds.isFinite, seconds >= 0, seconds <= Date().timeIntervalSince1970 + 86400 else { return nil }
                return MigrationVisit(url: url, title: String(($0["title"] as String? ?? "").prefix(2000)), date: Date(timeIntervalSince1970: seconds))
            }
        }
    }
    static func chromiumBookmark(_ node: [String: Any], depth: Int) throws -> MigrationBookmark {
        guard depth < 32 else { throw MigrationFailure.tooLarge }
        return MigrationBookmark(title: String((node["name"] as? String ?? "Imported").prefix(2000)), url: MigrationInput.url(node["url"] as? String), children: try (node["children"] as? [[String: Any]] ?? []).map { try chromiumBookmark($0, depth: depth + 1) })
    }
    static func safariBookmarks(_ node: [String: Any], depth: Int) throws -> [MigrationBookmark] {
        guard depth < 32 else { throw MigrationFailure.tooLarge }
        let title = (node["URIDictionary"] as? [String: Any])?["title"] as? String ?? node["Title"] as? String ?? "Imported"
        if let url = MigrationInput.url(node["URLString"] as? String) { return [.init(title: String(title.prefix(2000)), url: url)] }
        let children = try (node["Children"] as? [[String: Any]] ?? []).flatMap { try safariBookmarks($0, depth: depth + 1) }
        return depth == 0 ? children : [.init(title: String(title.prefix(2000)), children: children)]
    }
    static func geckoBookmarks(_ file: URL) throws -> [MigrationBookmark] {
        try database(file) { db in
            let rows = try Row.fetchAll(db, sql: "SELECT b.id,b.parent,b.type,b.title,p.url FROM moz_bookmarks b LEFT JOIN moz_places p ON p.id=b.fk ORDER BY b.position LIMIT 100001")
            guard rows.count <= 100_000 else { throw MigrationFailure.tooLarge }
            let groups = Dictionary(grouping: rows, by: { $0["parent"] as Int64 })
            var seen = Set<Int64>()
            func walk(_ parent: Int64, depth: Int) throws -> [MigrationBookmark] {
                guard depth < 32 else { throw MigrationFailure.tooLarge }
                return try (groups[parent] ?? []).compactMap { row in
                    let id: Int64 = row["id"]
                    guard seen.insert(id).inserted else { throw MigrationFailure.invalid }
                    let title = String((row["title"] as String? ?? "Imported").prefix(2000)), type: Int = row["type"]
                    if type == 1, let url = MigrationInput.url(row["url"]) { return .init(title: title, url: url) }
                    if type == 2 { return .init(title: title, children: try walk(id, depth: depth + 1)) }
                    return nil
                }
            }
            return try walk(0, depth: 0)
        }
    }
    static func html(_ data: Data) throws -> [MigrationBookmark] {
        let document = try XMLDocument(data: data, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever])
        guard let root = try document.nodes(forXPath: "//dl | //DL").first else { throw MigrationFailure.invalid }
        var count = 0
        func walk(_ node: XMLNode, depth: Int) throws -> [MigrationBookmark] {
            guard depth < 32 else { throw MigrationFailure.tooLarge }
            var items: [MigrationBookmark] = []
            for child in node.children ?? [] {
                count += 1; guard count <= 100_000 else { throw MigrationFailure.tooLarge }
                if child.name?.lowercased() == "a", let element = child as? XMLElement,
                   let url = MigrationInput.url(element.attribute(forName: "href")?.stringValue ?? element.attribute(forName: "HREF")?.stringValue) {
                    items.append(.init(title: String((child.stringValue ?? "Imported").prefix(2000)), url: url))
                } else if let title = child.children?.first(where: { $0.name?.lowercased() == "h3" })?.stringValue {
                    items.append(.init(title: String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000)), children: try walk(child, depth: depth + 1)))
                } else if child.name?.lowercased() == "dl", let last = items.indices.last,
                          items[last].url == nil, items[last].children.isEmpty {
                    // Netscape exports commonly put the folder's DL next to its DT.
                    items[last].children = try walk(child, depth: depth + 1)
                } else { items += try walk(child, depth: depth + 1) }
            }
            return items
        }
        return try walk(root, depth: 0)
    }
}
