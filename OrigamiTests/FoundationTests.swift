import Foundation
import Testing
import GRDB
@testable import Origami

struct FoundationTests {
    private func database() throws -> DatabaseManager {
        let db = try DatabaseManager()
        _ = try ProfileRepository(db).ensureDefault()
        return db
    }
    @Test func migrationsInitializeAndUpgrade() throws {
        let db = try DatabaseManager(migrate: false)
        let migrator = Migrations.make()
        try migrator.migrate(db.queue, upTo: Migrations.names[1])
        _ = try ProfileRepository(db).ensureDefault()
        try migrator.migrate(db.queue)
        try migrator.migrate(db.queue)
        try db.queue.read { (database: Database) throws -> Void in
            #expect(try String.fetchAll(database, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier") == Migrations.names.sorted())
            for table in ["profiles", "browser_sessions", "windows", "tabs", "tab_groups", "recently_closed", "history_pages", "history_visits", "bookmarks", "bookmark_folders", "downloads", "permissions"] {
                #expect(try database.tableExists(table))
            }
            #expect(try Int.fetchOne(database, sql: "PRAGMA foreign_keys") == 1)
        }
        #expect(try ProfileRepository(db).list().count == 1)
    }
    @Test func migrationFailureRollsBackWithoutDeletingExistingData() throws {
        let db = try database()
        var migrator = Migrations.make()
        migrator.registerMigration("v7_test_failure") { db in
            try db.execute(sql: "CREATE TABLE unfinished(id INTEGER); INSERT INTO missing_table VALUES (1)")
        }
        #expect(throws: (any Error).self) { try migrator.migrate(db.queue) }
        #expect(try db.queue.read { try !$0.tableExists("unfinished") })
        #expect(try ProfileRepository(db).list().count == 1)
    }
    @Test func profilesUseSeparateWebsiteIdentifiers() throws {
        let db = try database()
        let repository = ProfileRepository(db)
        let first = try repository.create(name: "Work")
        let second = try repository.create(name: "Personal")
        #expect(first.id != second.id)
        #expect(first.websiteStoreID != second.websiteStoreID)
        #expect(first.websiteStoreID != nil)
        #expect(try repository.ensureDefault().websiteStoreID == nil)
    }
    @Test func historyPagesAndVisitsAreNormalizedAndProfileScoped() throws {
        let db = try database()
        let repository = HistoryRepository(db)
        let first = BrowserProfile.defaultID
        let second = try ProfileRepository(db).create(name: "Other").id
        try repository.record(URL(string: "https://EXAMPLE.com:443/#first")!, title: "One", profileID: first, at: Date(timeIntervalSince1970: 10))
        try repository.record(URL(string: "https://example.com/#second")!, title: "Two", profileID: first, at: Date(timeIntervalSince1970: 20))
        try repository.record(URL(string: "https://example.com/")!, title: "Other", profileID: second)
        let visits = try repository.list(profileID: first)
        #expect(visits.count == 2)
        #expect(visits[0].pageID == visits[1].pageID)
        #expect(visits[0].visitedAt > visits[1].visitedAt)
        #expect(visits[0].title == "Two")
        #expect(try repository.list(profileID: second).count == 1)
        #expect(try db.queue.read { try Int.fetchOne($0, sql: "SELECT visit_count FROM history_pages WHERE profile_id=?", arguments: [first.uuidString]) } == 2)
        try repository.delete(pageID: visits[0].pageID, profileID: second)
        #expect(try repository.list(profileID: first).count == 2)
        try repository.delete(pageID: visits[0].pageID, profileID: first)
        #expect(try repository.list(profileID: first).isEmpty)
        #expect(HistoryRepository.normalized(InternalRoute.newTabURL) == nil)
    }
    @Test func bookmarkCRUDOrderingAndFolderBoundaries() throws {
        let db = try database()
        let repository = BookmarkRepository(db)
        let profile = BrowserProfile.defaultID
        let other = try ProfileRepository(db).create(name: "Other").id
        let root = try repository.createFolder(title: "Root", profileID: profile)
        let child = try repository.createFolder(title: "Child", parentID: root, profileID: profile)
        let first = try repository.create(url: URL(string: "https://example.com")!, title: "First", folderID: child, position: 1, profileID: profile)
        let second = try repository.create(url: URL(string: "https://apple.com")!, title: "Second", folderID: child, position: 0, profileID: profile)
        #expect(try repository.list(profileID: profile).map(\.id) == [second, first])
        try repository.update(first, title: "Changed", folderID: root, position: -1, profileID: profile)
        #expect(try repository.list(profileID: profile).first?.title == "Changed")
        #expect(throws: (any Error).self) { try repository.createFolder(title: "Bad", parentID: root, profileID: other) }
        try repository.renameFolder(root, title: "Renamed", profileID: profile)
        #expect(try repository.folders(profileID: profile).contains { $0.title == "Renamed" })
        try repository.delete(second, profileID: other)
        #expect(try repository.list(profileID: profile).count == 2)
        try repository.deleteFolder(root, profileID: profile)
        #expect(try repository.list(profileID: profile).isEmpty)
        #expect(try repository.folders(profileID: profile).isEmpty)
    }
    @Test func permissionsPersistAndResetWithProfileDefaults() throws {
        let db = try database()
        let profile = BrowserProfile.defaultID
        let other = try ProfileRepository(db).create(name: "Other").id
        let service = PermissionService(db)
        let origin = "https://example.com"
        #expect(try service.decision(.camera, origin: origin, profileID: profile) == .ask)
        try service.set(.block, category: .camera, origin: "*", profileID: profile)
        try service.set(.allow, category: .camera, origin: origin, profileID: profile)
        #expect(try PermissionService(db).decision(.camera, origin: origin, profileID: profile) == .allow)
        #expect(try service.decision(.camera, origin: origin, profileID: other) == .ask)
        try service.reset(profileID: profile, origin: origin)
        #expect(try service.decision(.camera, origin: origin, profileID: profile) == .block)
        try service.reset(profileID: profile)
        #expect(try service.decision(.camera, origin: origin, profileID: profile) == .ask)
        #expect(throws: (any Error).self) { try service.set(.allow, category: .camera, origin: "https://example.com/path", profileID: profile) }
    }
    @Test func sessionsSkipMalformedRowsAndSaveAtomically() throws {
        let db = try database()
        let repository = SessionRepository(db)
        var session = BrowserSession()
        let good = BrowserTab(url: URL(string: "https://example.com"))
        let invalid = BrowserTab(url: URL(string: "https://apple.com"))
        session.tabs = [good, invalid]; session.selectedTabID = good.id
        try repository.save(session)
        try db.queue.write { try $0.execute(sql: "UPDATE tabs SET url='javascript:alert(1)' WHERE id=?", arguments: [invalid.id.uuidString]) }
        let restored = try #require(try repository.load(profileID: session.profileID))
        #expect(restored.tabs.count == 2)
        #expect(restored.tabs[1].url == nil)
        #expect(restored.selectedTabID == good.id)
        session.tabs[0].groupID = UUID()
        #expect(throws: (any Error).self) { try repository.save(session) }
        #expect(try repository.load(profileID: session.profileID) == restored)
    }
    @Test func windowsAndClosedTabsAreIndependent() throws {
        let db = try database()
        let repository = SessionRepository(db)
        var first = BrowserSession(); first.tabs[0].url = URL(string: "https://example.com"); first.normalize()
        var second = first; second.windowID = UUID(); second.tabs = [BrowserTab()]; second.normalize()
        try repository.save(first, recentlyClosed: [(first.tabs[0], 0)])
        try repository.save(second)
        #expect(try db.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM windows") } == 2)
        #expect(try RecentlyClosedRepository(db).list(profileID: first.profileID, windowID: first.windowID).count == 1)
        #expect(try RecentlyClosedRepository(db).list(profileID: first.profileID, windowID: second.windowID).isEmpty)
    }
    @Test func downloadsPersistAndRecoverInterruptedState() throws {
        let db = try database()
        let repository = DownloadRepository(db)
        var record = DownloadRecord(profileID: BrowserProfile.defaultID, tabID: UUID(), url: "https://example.com/file")
        record.state = .running; record.received = 20; record.expected = 100
        try repository.save(record)
        try repository.recoverInterrupted()
        #expect(try repository.list(profileID: record.profileID).first?.state == .interrupted)
        record.state = .completed; record.received = 100
        try repository.save(record)
        #expect(try repository.list(profileID: record.profileID).first?.received == 100)
        #expect(try repository.list(profileID: UUID()).isEmpty)
    }
    @Test func internalRoutesRejectSpoofedAndMalformedURLs() {
        for page in InternalPage.allCases { #expect(InternalRoute.page(for: URL(string: "origami://\(page.rawValue)")!) == page) }
        for text in ["https://newtab", "origami://newtab.evil", "origami://user@newtab", "origami://newtab:80", "origami://newtab/../settings", "origami://newtab?x=1", "origami://ask", "origami://assets/app.js"] {
            #expect(InternalRoute.page(for: URL(string: text)!) == nil)
        }
    }
    @MainActor @Test func lifecyclePolicyIsConservative() {
        var activity = TabActivity(lastActive: .distantPast)
        let policy = TabLifecycleService()
        #expect(!policy.maySleep(activity, pinned: false, selected: false))
        activity.backgroundActivityKnownSafe = true
        #expect(policy.maySleep(activity, pinned: false, selected: false))
        #expect(!policy.maySleep(activity, pinned: true, selected: false))
        #expect(!policy.maySleep(activity, pinned: false, selected: true))
        activity.hasDownload = true
        #expect(!policy.maySleep(activity, pinned: false, selected: false))
    }
}
