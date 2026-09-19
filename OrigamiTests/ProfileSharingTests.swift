import Testing
import Foundation
import WebKit
import GRDB
@testable import Origami

@MainActor struct ProfileSharingTests {
    @Test func migrationPreservesIsolationAndExistingAppearanceDefaults() throws {
        let db = try DatabaseManager(migrate: false)
        try Migrations.make().migrate(db.queue, upTo: "v16_web_highlights")
        let id = UUID()
        try db.queue.write { db in
            try db.execute(sql: "INSERT INTO profiles(id,name,created_at,website_store_id,color) VALUES (?,?,0,?,'blue')",
                           arguments: [id.uuidString, "Fixture", UUID().uuidString])
        }
        try Migrations.make().migrate(db.queue)
        let profile = try #require(ProfileRepository(db).list().first)
        #expect(profile.id == id)
        #expect(profile.sharing == ProfileSharing())
        #expect(try ProfileRepository(db).scope(id, .history) == id)
        #expect(try ProfileRepository(db).scope(id, .appearance) == BrowserProfile.defaultID)
    }
    @Test func independentSharingRestoresOwnDataWithoutMerging() throws {
        let db = try DatabaseManager(), profiles = ProfileRepository(db)
        let personal = try profiles.ensureDefault(), work = try profiles.create(name: "Work")
        let history = HistoryRepository(db), bookmarks = BookmarkRepository(db)
        let ownURL = URL(string: "https://own.invalid/")!, sharedURL = URL(string: "https://shared.invalid/")!
        try history.record(ownURL, title: "Own", profileID: work.id)
        try history.record(sharedURL, title: "Shared", profileID: personal.id)
        _ = try bookmarks.create(url: ownURL, title: "Own", profileID: work.id)
        _ = try bookmarks.create(url: sharedURL, title: "Shared", profileID: personal.id)
        var sharing = ProfileSharing(); sharing.history = true
        try profiles.setSharing(sharing, for: work.id)
        #expect(try history.list(profileID: work.id).first?.title == "Shared")
        #expect(try bookmarks.list(profileID: work.id).first?.title == "Own")
        sharing.bookmarks = true; try profiles.setSharing(sharing, for: work.id)
        #expect(try bookmarks.list(profileID: work.id).first?.title == "Shared")
        _ = try bookmarks.addUnique(url: URL(string: "https://new.invalid")!, title: "New", profileID: work.id)
        #expect(try bookmarks.list(profileID: personal.id).count == 2)
        try history.clear(profileID: work.id, since: .distantPast)
        #expect(try history.list(profileID: personal.id).isEmpty)
        try profiles.setSharing(ProfileSharing(), for: work.id)
        #expect(try history.list(profileID: work.id).first?.title == "Own")
        #expect(try bookmarks.list(profileID: work.id).first?.title == "Own")
    }
    @Test func sharedBookmarkFoldersImportSearchAndDeletionUseSameScope() throws {
        let db = try DatabaseManager(), profiles = ProfileRepository(db)
        _ = try profiles.ensureDefault()
        let work = try profiles.create(name: "Work")
        var sharing = ProfileSharing(); sharing.bookmarks = true
        try profiles.setSharing(sharing, for: work.id)
        let bookmarks = BookmarkRepository(db)
        let folder = try bookmarks.createFolder(title: "Folder", profileID: work.id)
        let item = try bookmarks.create(url: URL(string: "https://example.invalid")!, title: "Fixture", folderID: folder, profileID: work.id)
        #expect(try bookmarks.folderBookmarks(folder, profileID: work.id).count == 1)
        #expect(try bookmarks.suggestionCandidates(query: "Fixture", profileID: work.id).count == 1)
        #expect(try bookmarks.library(profileID: work.id, folderID: folder).count == 1)
        #expect(try bookmarks.importItems([.bookmark("Imported", URL(string: "https://import.invalid")!)], profileID: work.id) == 1)
        try bookmarks.delete(item, profileID: work.id)
        #expect(try bookmarks.list(profileID: BrowserProfile.defaultID).count == 1)
        try profiles.delete(work.id)
        #expect(try bookmarks.list(profileID: BrowserProfile.defaultID).count == 1)
    }
    @Test func websiteSharingAndPrivateStorageRemainSeparate() throws {
        let db = try DatabaseManager(), profiles = ProfileRepository(db)
        let personal = try profiles.ensureDefault()
        var work = try profiles.create(name: "Work")
        let website = WebsiteDataService()
        #expect(website.store(for: work).identifier == work.websiteStoreID)
        work.sharing.website = true
        #expect(website.store(for: work).identifier == website.store(for: personal).identifier)
        let ephemeral = WKWebsiteDataStore.nonPersistent()
        let privateWebsite = WebsiteDataService(ephemeralStore: ephemeral)
        #expect(privateWebsite.store(for: work) === ephemeral)
        #expect(!privateWebsite.store(for: work).isPersistent)
        work.sharing.history = true
        let privateServices = try BrowserServices(database: DatabaseManager(), privateProfile: work)
        try privateServices.history.record(URL(string: "https://private.invalid")!, title: "Private", profileID: work.id)
        #expect(try privateServices.history.list(profileID: BrowserProfile.defaultID).isEmpty)
        #expect(try HistoryRepository(db).list(profileID: work.id).isEmpty)
    }
    @Test func appearanceAndLayoutPersistIndependentlyWithoutScopingSearch() throws {
        let name = "Origami.ProfileSharingTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = BrowserPreferences(defaults: defaults), id = UUID()
        let personal = prefs.appearance(for: BrowserProfile.defaultID)
        personal.hex = "3478F6"
        let own = prefs.appearance(for: id)
        #expect(own.hex == personal.hex)
        own.hex = "D65F78"; own.mode = "Dark"
        #expect(personal.hex == "3478F6")
        #expect(BrowserPreferences(defaults: defaults).appearance(for: id).hex == "D65F78")
        prefs.layout = .horizontal; prefs.setProfileLayout(.vertical, for: id)
        #expect(prefs.layout == .horizontal && prefs.profileLayout(id) == .vertical)
        prefs.searchEngine = .google
        #expect(BrowserPreferences(defaults: defaults).searchEngine == .google)
    }
    @Test func websiteSharingRecreatesViewsAndPreservesTabs() throws {
        let app = BrowserApplicationContext(isolated: true)
        defer { for id in Array(app.stores.keys) { app.close(id) } }
        let services = try #require(app.services)
        let profile = try services.profiles.create(name: "Work")
        let store = try app.switchProfile(profile.id, in: app.resolve(nil))
        let tab = try #require(store.session.selectedTabID)
        let old = store.page(for: tab)
        let tabs = store.session.tabs.map(\.id)
        var sharing = ProfileSharing(); sharing.website = true; sharing.layout = false
        try app.updateProfile(profile.id, name: "Work", color: .blue, sharing: sharing)
        #expect(store.session.tabs.map(\.id) == tabs)
        #expect(store.pages.isEmpty)
        let fresh = store.page(for: tab)
        #expect(fresh !== old)
        #expect(fresh.webView.configuration.websiteDataStore.identifier == WKWebsiteDataStore.default().identifier)
    }
}
