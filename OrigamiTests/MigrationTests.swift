import Foundation
import Testing
import GRDB
@testable import Origami

struct MigrationTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    @Test func everyRequestedBrowserAcceptsSafeBookmarkExports() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "bookmarks.html")
        try Data("<DL><DT><A HREF='https://example.invalid/'>Example</A><DT><A HREF='javascript:alert(1)'>Unsafe</A></DL>".utf8).write(to: file)
        #expect(MigrationBrowser.allCases.count == 10)
        for browser in MigrationBrowser.allCases {
            let result = try MigrationReader.read(file, browser: browser)
            #expect(result.first?.bookmarkCount == 1)
            #expect(result.first?.history == nil && result.first?.tabs == nil)
        }
    }
    @Test func chromiumProfilesKeepTheirOwnBookmarksHistoryAndNames() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Default", "Profile 1"] {
            let directory = root.appending(path: name); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let bookmark: [String: Any] = ["roots": ["bookmark_bar": ["name": "Favorites", "children": [["name": name, "url": "https://example.invalid/\(name == "Default" ? "one" : "two")"]]]]]
            try JSONSerialization.data(withJSONObject: bookmark).write(to: directory.appending(path: "Bookmarks"))
            try JSONSerialization.data(withJSONObject: ["profile": ["name": name], "default_search_provider": ["name": "DuckDuckGo"]]).write(to: directory.appending(path: "Preferences"))
            let db = try DatabaseQueue(path: directory.appending(path: "History").path)
            try db.write { d in
                try d.execute(sql: "CREATE TABLE urls(id INTEGER PRIMARY KEY,url TEXT,title TEXT); CREATE TABLE visits(url INTEGER,visit_time REAL)")
                try d.execute(sql: "INSERT INTO urls VALUES(1,'https://example.invalid/','Fixture'); INSERT INTO visits VALUES(1,13348540800000000)")
            }
            // Forbidden source categories need not even be readable for an import to succeed.
            try Data("not a password database".utf8).write(to: directory.appending(path: "Login Data"))
        }
        let system = root.appending(path: "System Profile")
        try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: system.appending(path: "Preferences"))
        let profiles = try MigrationReader.read(root, browser: .chrome)
        #expect(profiles.count == 2)
        #expect(profiles.allSatisfy { $0.bookmarkCount == 1 && $0.history?.count == 1 && $0.search == "duckDuckGo" })
    }
    @Test func firefoxHistoryBookmarksAndCompressedSession() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let db = try DatabaseQueue(path: root.appending(path: "places.sqlite").path)
        try db.write { d in
            try d.execute(sql: "CREATE TABLE moz_places(id INTEGER,url TEXT,title TEXT); CREATE TABLE moz_historyvisits(place_id INTEGER,visit_date REAL); CREATE TABLE moz_bookmarks(id INTEGER,parent INTEGER,type INTEGER,title TEXT,fk INTEGER,position INTEGER)")
            try d.execute(sql: "INSERT INTO moz_places VALUES(1,'https://example.invalid/','Fixture'); INSERT INTO moz_historyvisits VALUES(1,1704067200000000); INSERT INTO moz_bookmarks VALUES(1,0,2,'Root',NULL,0),(2,1,1,'Bookmark',1,0)")
        }
        let state = Data(#"{"windows":[{"tabs":[{"pinned":true,"index":1,"entries":[{"url":"https://example.invalid/","title":"Open"}]}]},{"isPrivate":true,"tabs":[{"entries":[{"url":"https://private.invalid/"}]}]}]}"#.utf8)
        try literalLZ4(state).write(to: root.appending(path: "sessionstore.jsonlz4"))
        let p = try #require(MigrationReader.read(root, browser: .firefox).first)
        #expect(p.bookmarkCount == 1 && p.history?.count == 1)
        #expect(p.tabs?.count == 1 && p.tabs?.first?.pinned == true)
        #expect(try GeckoMigrationSession.decode(literalLZ4(state)) == state)
        #expect(throws: MigrationFailure.self) { try GeckoMigrationSession.decode(Data("mozLz40\0bad".utf8)) }
    }
    private func literalLZ4(_ data: Data) -> Data {
        var result = Data("mozLz40\0".utf8)
        for shift in stride(from: 0, to: 32, by: 8) { result.append(UInt8((data.count >> shift) & 255)) }
        result.append(UInt8(min(15, data.count) << 4))
        if data.count >= 15 {
            var rest = data.count - 15
            while rest >= 255 { result.append(255); rest -= 255 }; result.append(UInt8(rest))
        }
        result.append(data); return result
    }
    @Test func safariPlistAndHistoryUseTheirOwnTimeBase() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let tree: [String: Any] = ["Children": [["URLString": "https://example.invalid/", "URIDictionary": ["title": "Fixture"]]]]
        try PropertyListSerialization.data(fromPropertyList: tree, format: .binary, options: 0).write(to: root.appending(path: "Bookmarks.plist"))
        let db = try DatabaseQueue(path: root.appending(path: "History.db").path)
        try db.write { d in
            try d.execute(sql: "CREATE TABLE history_items(id INTEGER,url TEXT); CREATE TABLE history_visits(history_item INTEGER,title TEXT,visit_time REAL); INSERT INTO history_items VALUES(1,'https://example.invalid/'); INSERT INTO history_visits VALUES(1,'Fixture',725760000)")
        }
        let p = try #require(MigrationReader.read(root, browser: .safari).first)
        #expect(p.bookmarkCount == 1)
        #expect(p.history?.first?.date.timeIntervalSince1970 == 1704067200)
    }
    @Test func newProfileAndReplacementAreAtomicAndPreserveUnselectedData() throws {
        let db = try DatabaseManager(); _ = try ProfileRepository(db).ensureDefault()
        let url = URL(string: "https://existing.invalid/")!
        let original = try BookmarkRepository(db).create(url: url, title: "Existing", profileID: BrowserProfile.defaultID)
        var profile = MigrationProfile(name: "Imported", bookmarks: [.init(title: "New", url: URL(string: "https://new.invalid/")!)])
        let imported = try MigrationWriter.apply(profile, selection: .init(), database: db)
        #expect(imported.profileID != BrowserProfile.defaultID)
        #expect(try BookmarkRepository(db).list(profileID: BrowserProfile.defaultID).first?.id == original)
        #expect(try BookmarkRepository(db).list(profileID: imported.profileID).count == 1)
        var current = BrowserSession(); current.profileID = BrowserProfile.defaultID
        // Force a failure after destination deletes. The transaction must restore old data.
        profile.bookmarks = [.init(title: "Bad", url: URL(string: "file:///invalid")!)]
        #expect(throws: MigrationFailure.self) { try MigrationWriter.apply(profile, selection: .init(), database: db, replacing: current) }
        #expect(try BookmarkRepository(db).list(profileID: BrowserProfile.defaultID).first?.id == original)
        profile.bookmarks = nil; profile.history = []
        _ = try MigrationWriter.apply(profile, selection: .init(), database: db, replacing: current)
        #expect(try BookmarkRepository(db).list(profileID: BrowserProfile.defaultID).count == 1)
    }
    @Test func sharedProfilesAndEscapingSymlinksAreRejected() throws {
        let db = try DatabaseManager(); _ = try ProfileRepository(db).ensureDefault()
        var sharing = ProfileSharing(); sharing.bookmarks = true
        let profile = try ProfileRepository(db).create(name: "Shared", sharing: sharing)
        var current = BrowserSession(); current.profileID = profile.id
        #expect(throws: MigrationFailure.self) { try MigrationWriter.apply(MigrationProfile(name: "Source", bookmarks: []), selection: .init(), database: db, replacing: current) }
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let outside = try folder(); defer { try? FileManager.default.removeItem(at: outside) }
        let target = outside.appending(path: "fixture"); try Data().write(to: target)
        try FileManager.default.createSymbolicLink(atPath: root.appending(path: "Bookmarks").path, withDestinationPath: target.path)
        #expect(throws: MigrationFailure.self) { try MigrationInput.child("Bookmarks", in: root) }
        #expect(MigrationInput.url("https://user:password@example.invalid/") == nil)
        #expect(MigrationInput.url("origami://settings") == nil)
    }
}

extension MigrationTests {
    @Test func databaseReadsLeaveSourceDirectoryUntouchedAndRejectExternalWAL() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "History")
        let source = try DatabaseQueue(path: file.path)
        try source.write { try $0.execute(sql: "CREATE TABLE fixture(value INTEGER); INSERT INTO fixture VALUES (42)") }
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        #expect(try MigrationReader.database(file) { try Int.fetchOne($0, sql: "SELECT value FROM fixture") } == 42)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == before)
        try source.close()
        let outside = try folder(); defer { try? FileManager.default.removeItem(at: outside) }
        let target = outside.appending(path: "fixture"); try Data().write(to: target)
        try FileManager.default.createSymbolicLink(atPath: file.path + "-wal", withDestinationPath: target.path)
        #expect(throws: MigrationFailure.self) { try MigrationReader.database(file) { _ in 0 } }
    }
    @Test func bookmarkExportRetainsFolderHierarchy() throws {
        let result = try MigrationReader.html(Data("<DL><DT><H3>Work</H3><DL><DT><A HREF='https://example.invalid/'>One</A></DL><DT><A HREF='https://other.invalid/'>Two</A></DL>".utf8))
        #expect(result.first?.title == "Work")
        #expect(result.first?.children.first?.url?.host == "example.invalid")
        #expect(result.last?.url?.host == "other.invalid")
    }
    @Test func chromiumSessionRestoresSelectedNavigationAndPinnedState() throws {
        func int(_ n: Int, bytes: Int = 4) -> Data { Data((0..<bytes).map { UInt8((n >> ($0 * 8)) & 255) }) }
        var data = Data("SNSS".utf8) + int(1)
        func command(_ id: UInt8, _ payload: Data) { data += int(payload.count + 1, bytes: 2); data.append(id); data += payload }
        command(0, int(1) + int(2)); command(7, int(2) + int(0)); command(12, int(2) + Data([1]))
        let url = Data("https://example.invalid/".utf8), title = Data("Fixture".utf16.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] })
        var body = int(2) + int(0) + int(url.count) + url
        body += Data(repeating: 0, count: (4 - url.count % 4) % 4)
        body += int(7) + title
        command(6, int(body.count) + body)
        let result = try ChromiumMigrationSession.parse(data)
        #expect(result.count == 1 && result.first?.pinned == true && result.first?.title == "Fixture")
        #expect(throws: MigrationFailure.self) { try ChromiumMigrationSession.parse(data.dropLast()) }
        var modern = data; modern.replaceSubrange(4..<8, with: int(3))
        #expect(throws: MigrationFailure.self) { try ChromiumMigrationSession.parse(modern) }
        modern += int(1, bytes: 2); modern.append(255)
        #expect(try ChromiumMigrationSession.parse(modern).first?.pinned == true)
        command(16, int(2))
        #expect(try ChromiumMigrationSession.parse(data).isEmpty)
        #expect(throws: MigrationFailure.self) { try ChromiumMigrationSession.parse(Data("SNSS".utf8) + int(5)) }
    }
}
