import AppKit
import Testing
@testable import Origami

@MainActor
struct BookmarkPresentationTests {
    @Test func editingAndRemovingPageBookmarksPreservesProfileAndFavoriteState() throws {
        let database = try DatabaseManager()
        let profiles = ProfileRepository(database)
        let personal = try profiles.ensureDefault().id
        let work = try profiles.create(name: "Work").id
        let repo = BookmarkRepository(database)
        let url = URL(string: "https://example.com")!
        let editedURL = URL(string: "https://example.com/docs")!
        let folder = try repo.createFolder(title: "Docs", profileID: personal)
        let id = try repo.create(url: url, title: "Original", profileID: personal)
        try repo.edit(id, url: url, title: "Original", folderID: nil, favorite: true, profileID: personal)
        try repo.editDetails(id, url: editedURL, title: "Documentation", folderID: folder, profileID: personal)
        let edited = try #require(try repo.bookmark(url: editedURL, profileID: personal))
        #expect(edited.id == id && edited.title == "Documentation" && edited.folderID == folder)
        #expect(try repo.library(profileID: personal, folderID: folder, favorites: true).count == 1)
        _ = try repo.create(url: editedURL, title: "Duplicate", profileID: personal)
        _ = try repo.create(url: editedURL, title: "Work copy", profileID: work)
        try repo.removePage(url: editedURL, profileID: personal)
        #expect(try !repo.contains(url: editedURL, profileID: personal))
        #expect(try repo.contains(url: editedURL, profileID: work))
    }

    @Test func compactPreferenceSurvivesReload() throws {
        let suite = "Origami.BookmarkPresentationTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = BrowserPreferences(defaults: defaults)
        #expect(!preferences.compactBookmarks)
        preferences.compactBookmarks = true
        #expect(BrowserPreferences(defaults: defaults).compactBookmarks)
        preferences.compactBookmarks = false
        #expect(!BrowserPreferences(defaults: defaults).compactBookmarks)
    }
    @Test func faviconsReuseSiteIdentityWithinTheirProfile() async throws {
        let icons = FaviconService(), first = UUID(), second = UUID()
        let url = URL(string: "https://example.com/page")!
        let image = NSImage(size: NSSize(width: 16, height: 16))
        icons.remember(image, for: url, profile: first)
        #expect(icons.cached(URL(string: "https://example.com/another")!, profile: first) === image)
        #expect(icons.cached(url, profile: second) == nil)
        #expect(icons.cached(URL(string: "https://other.example.com")!, profile: first) == nil)
        #expect(await icons.load(url, profile: first) === image)
        #expect(await icons.load(InternalPage.newtab.url, profile: first) == nil)
        #expect(FaviconService.origin(URL(string: "file:///tmp/icon")) == nil)
    }
}
