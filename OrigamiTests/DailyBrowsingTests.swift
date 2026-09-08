import Foundation
import Testing
import GRDB
import WebKit
@testable import Origami

struct DailyBrowsingTests {
    private func database() throws -> DatabaseManager {
        let db = try DatabaseManager(); _ = try ProfileRepository(db).ensureDefault(); return db
    }
    @Test func migrationKeepsPhase2AData() throws {
        let db = try DatabaseManager(migrate: false)
        try Migrations.make().migrate(db.queue, upTo: "v6_permissions")
        _ = try ProfileRepository(db).ensureDefault()
        try BookmarkRepository(db).create(url: URL(string: "https://example.com")!, title: "Kept", profileID: BrowserProfile.defaultID)
        try Migrations.make().migrate(db.queue)
        #expect(try BookmarkRepository(db).library(profileID: BrowserProfile.defaultID, folderID: nil).first?["title"] as? String == "Kept")
    }
    @Test func largeTimelineUsesStableCursorsAndProfileDateFilters() throws {
        let db = try database(), profile = BrowserProfile.defaultID
        let other = try ProfileRepository(db).create(name: "Work").id
        let history = HistoryRepository(db)
        try history.record(URL(string: "https://example.com")!, title: "Example", profileID: profile, at: Date(timeIntervalSince1970: 1000))
        try history.record(URL(string: "https://example.com")!, title: "Other", profileID: other, at: Date(timeIntervalSince1970: 1000))
        try db.queue.write { db in
            try db.execute(sql: "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<10000) INSERT INTO history_visits(page_id,profile_id,visited_at) SELECT (SELECT id FROM history_pages WHERE profile_id=?),?,1000+(x/10) FROM n", arguments: [profile.uuidString, profile.uuidString])
        }
        var query = TimelineQuery(); query.domain = "example.com"
        let first = try history.timeline(profileID: profile, query: query)
        #expect(first.count == 100)
        query.beforeTime = first.last?["time"] as? Double; query.beforeID = first.last?["id"] as? Int64 ?? 0
        let second = try history.timeline(profileID: profile, query: query)
        #expect(second.count == 100)
        #expect(Set(first.compactMap { $0["id"] as? Int64 }).isDisjoint(with: second.compactMap { $0["id"] as? Int64 }))
        query.text = "%"; #expect(try history.timeline(profileID: profile, query: query).isEmpty)
        try history.clear(profileID: profile, since: Date(timeIntervalSince1970: 1500))
        #expect(try history.timeline(profileID: other, query: TimelineQuery()).count == 1)
        let remaining = try history.timeline(profileID: profile, query: TimelineQuery())
        #expect(remaining.allSatisfy { ($0["time"] as? Double ?? 0) < 1500 })
    }
    @Test func bookmarkHTMLRoundTripEscapesAndPreservesNestedFolders() throws {
        let db = try database(), profile = BrowserProfile.defaultID
        let bookmarks = BookmarkRepository(db), html = BookmarkHTMLService(bookmarks)
        let root = try bookmarks.createFolder(title: "Work & <Projects>", profileID: profile)
        let child = try bookmarks.createFolder(title: "Nested", parentID: root, profileID: profile)
        let id = try bookmarks.addUnique(url: URL(string: "https://example.com/?a=1&b=2")!, title: "<script> & title", folderID: child, profileID: profile)
        #expect(try bookmarks.addUnique(url: URL(string: "https://example.com/?a=1&b=2")!, title: "Duplicate", folderID: child, profileID: profile) == id)
        let exported = try html.exportHTML(profileID: profile)
        #expect(String(decoding: exported, as: UTF8.self).contains("&lt;script&gt;"))
        let other = try ProfileRepository(db).create(name: "Imported").id
        #expect(try html.importHTML(exported, profileID: other) == 1)
        let imported = try bookmarks.list(profileID: other)
        #expect(imported.first?.title == "<script> & title")
        #expect(try bookmarks.folders(profileID: other).count == 2)
        #expect(throws: (any Error).self) { try bookmarks.moveFolder(root, parentID: child, position: 0, profileID: profile) }
        #expect(throws: (any Error).self) { try bookmarks.edit(id, url: URL(string: "javascript:alert(1)")!, title: "Unsafe", folderID: nil, favorite: true, profileID: profile) }
    }
    @Test func bookmarksPaginateAndFavoritesShareModel() throws {
        let db = try database(), profile = BrowserProfile.defaultID, bookmarks = BookmarkRepository(db)
        for index in 0..<240 { try bookmarks.create(url: URL(string: "https://example.com/\(index)")!, title: "Item \(index)", position: index, profileID: profile) }
        #expect(try bookmarks.library(profileID: profile, folderID: nil).count == 100)
        #expect(try bookmarks.library(profileID: profile, folderID: nil, offset: 200).count == 40)
        let first = try #require(try bookmarks.list(profileID: profile).first)
        try bookmarks.edit(first.id, url: URL(string: first.url)!, title: "Favorite", folderID: nil, favorite: true, profileID: profile)
        #expect(try bookmarks.library(profileID: profile, folderID: nil, favorites: true).count == 1)
    }
    @Test func closedWindowsSleepingAndSelectionRoundTrip() throws {
        let db = try database(), repository = SessionRepository(db)
        var first = BrowserSession(), second = BrowserSession()
        first.tabs = (0..<55).map { _ in BrowserTab(url: URL(string: "https://example.com")) }
        first.tabs[1].isSleeping = true; first.selectedTabID = first.tabs[4].id
        second.tabs = [BrowserTab()]; second.normalize()
        try repository.save(first); try repository.save(second)
        #expect(try repository.windows().count == 2)
        try repository.closeWindow(first.windowID)
        #expect(try repository.windows().count == 1)
        let closed = try #require(try repository.windows(closed: true).first)
        #expect(closed.tabs.count == 55); #expect(closed.tabs[1].isSleeping == true)
        #expect(closed.selectedTabID == first.selectedTabID)
        try repository.save(closed); #expect(try repository.windows().count == 2)
    }
    @MainActor @Test func protocolDecisionsAndClearingAreProfileScoped() throws {
        let db = try database(), profile = BrowserProfile.defaultID
        let other = try ProfileRepository(db).create(name: "Other").id
        let permission = PermissionService(db), service = ExternalProtocolService(permissions: permission)
        try service.set(.allow, origin: "https://example.com", scheme: "mailto", profileID: profile)
        #expect(try service.decision(for: URL(string: "mailto:a@example.com")!, source: URL(string: "https://example.com"), profileID: profile) == .allow)
        #expect(try service.decision(for: URL(string: "slack:test")!, source: URL(string: "https://example.com"), profileID: profile) == .ask)
        #expect(try service.list(profileID: other).isEmpty)
        try service.set(.ask, origin: "https://example.com", scheme: "mailto", profileID: profile)
        #expect(try service.list(profileID: profile).isEmpty)
        try permission.set(.block, category: .camera, origin: "https://example.com", profileID: other)
        try permission.clear(profileID: profile, since: .distantPast)
        #expect(try permission.choices(profileID: other).count == 1)
    }
    @MainActor @Test func movingTabsRetainsWebViewAndEnforcesProfileBoundary() throws {
        let context = BrowserApplicationContext(isolated: true)
        let first = context.resolve(nil), second = context.newWindow()
        let id = first.newTab(url: URL(string: "https://example.com"))
        let page = first.page(for: id)
        context.moveTab(id, from: first, to: second)
        #expect(first.loadedPage(for: id) == nil)
        #expect(second.loadedPage(for: id)?.webView === page.webView)
        #expect(second.selectedTab?.id == id)
        second.session.tabs[second.session.tabs.firstIndex(where: { $0.id == id })!].isPinned = true
        #expect(second.session.tabs.count == 2)
        for window in context.stores.values { window.pages.values.forEach { $0.dispose() } }
    }
    @Test func failedWindowTransferRollsBackBothWindows() throws {
        let db = try database(), repo = SessionRepository(db)
        var source = BrowserSession(), target = BrowserSession()
        source.normalize(); target.normalize()
        try repo.save(source); try repo.save(target)
        let original = source
        var moved = source.tabs.removeFirst(); moved.groupID = UUID()
        target.tabs.append(moved)
        #expect(throws: (any Error).self) { try repo.transfer(source: source, sourceClosed: [], target: target, targetClosed: []) }
        #expect(try repo.load(profileID: source.profileID, windowID: source.windowID) == original)
        #expect(try repo.load(profileID: target.profileID, windowID: target.windowID)?.tabs.count == 1)
    }
    @MainActor @Test func profileWebKitCookieStoresAreActuallyIsolated() async throws {
        let db = try database(), profiles = ProfileRepository(db), service = WebsiteDataService()
        let first = try profiles.create(name: "Cookie test A"), second = try profiles.create(name: "Cookie test B")
        let one = service.store(for: first), two = service.store(for: second)
        let cookie = try #require(HTTPCookie(properties: [.domain: "origami-test.invalid", .path: "/", .name: "identity", .value: "first"]))
        await one.httpCookieStore.setCookie(cookie)
        let firstCookies = await one.httpCookieStore.allCookies(), secondCookies = await two.httpCookieStore.allCookies()
        #expect(firstCookies.contains { $0.name == "identity" && $0.value == "first" })
        #expect(!secondCookies.contains { $0.name == "identity" })
        await service.clear(profile: first); await service.clear(profile: second)
    }
    @MainActor @Test func defaultSearchChangesAcrossOpenWindows() {
        let context = BrowserApplicationContext(isolated: true)
        let first = context.resolve(nil), second = context.newWindow()
        first.setSearchEngine(.duckDuckGo)
        #expect(first.session.searchEngine == .duckDuckGo)
        #expect(second.session.searchEngine == .duckDuckGo)
    }
    @MainActor @Test func filenamesAvoidExistingAndConcurrentDestinations() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("a.pdf"))
        let first = DownloadService.availableDestination(directory: directory, filename: "../a.pdf")
        #expect(first.lastPathComponent == "a (1).pdf")
        let second = DownloadService.availableDestination(directory: directory, filename: "a.pdf", reserved: [first.path])
        #expect(second.lastPathComponent == "a (2).pdf")
    }
}
