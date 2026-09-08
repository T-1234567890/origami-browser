import Foundation
import WebKit
import Testing
@testable import Origami

@MainActor struct PrivateBrowsingTests {
    @Test func privateTabsShareCookiesButNotOtherWindows() async throws {
        let application = BrowserApplicationContext(isolated: true)
        let first = try #require(application.newPrivateWindow())
        let second = try #require(application.newPrivateWindow())
        defer { for id in Array(application.stores.keys) { application.close(id) } }
        let a = try #require(first.selectedPage)
        let b = first.page(for: first.newTab())
        let c = try #require(second.selectedPage)
        let data = a.webView.configuration.websiteDataStore
        #expect(!data.isPersistent)
        #expect(data === b.webView.configuration.websiteDataStore)
        #expect(data !== c.webView.configuration.websiteDataStore)
        #expect(try application.services?.websiteStore(profileID: BrowserProfile.defaultID).isPersistent == true)
        #expect(application.resolve(nil).selectedPage?.webView.configuration.websiteDataStore.isPersistent == true)
        let popupConfiguration = WKWebViewConfiguration()
        popupConfiguration.websiteDataStore = .default()
        let popup = first.page(for: first.newTab(), configuration: popupConfiguration)
        #expect(popup.webView.configuration.websiteDataStore === data)
        let cookie = try #require(HTTPCookie(properties: [.name: "private-fixture", .value: "signed-in", .domain: "private.invalid", .path: "/"]))
        await data.httpCookieStore.setCookie(cookie)
        #expect(await b.webView.configuration.websiteDataStore.httpCookieStore.allCookies().contains { $0.name == cookie.name })
        #expect(await c.webView.configuration.websiteDataStore.httpCookieStore.allCookies().isEmpty)
        application.close(first.session.windowID)
        for _ in 0..<100 {
            if await data.httpCookieStore.allCookies().isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await data.httpCookieStore.allCookies().isEmpty)
        #expect(first.pages.isEmpty)
    }
    @Test func privateStateNeverEntersSessionStorageButExplicitBookmarksRemain() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = SessionStore(fileURL: directory.appending(path: "browser.sqlite"))
        let application = BrowserApplicationContext(isolated: true, sessionStore: persistence)
        let normal = application.resolve(nil)
        normal.save()
        let privateWindow = try #require(application.newPrivateWindow())
        let services = try #require(privateWindow.services)
        let id = privateWindow.newTab(url: URL(string: "https://private.invalid/query?secret=value")!)
        privateWindow.save()
        #expect(privateWindow.persistence == nil)
        try services.permissions.set(.allow, category: .camera, origin: "https://private.invalid", profileID: privateWindow.session.profileID)
        try services.bookmarks.create(url: URL(string: "https://saved.invalid")!, title: "Explicit bookmark", profileID: privateWindow.session.profileID)
        #expect(try application.services?.bookmarks.list(profileID: privateWindow.session.profileID).count == 1)
        #expect(try application.services?.permissions.decision(.camera, origin: "https://private.invalid", profileID: privateWindow.session.profileID) == .ask)
        #expect(try application.services?.history.list(profileID: privateWindow.session.profileID).isEmpty == true)
        let count = privateWindow.session.tabs.count
        application.moveTab(id, from: privateWindow, to: normal)
        #expect(privateWindow.session.tabs.count == count)
        privateWindow.close(id)
        #expect(privateWindow.recentlyClosed.isEmpty)
        application.close(privateWindow.session.windowID)
        let windows = try SessionRepository(persistence.database).windows()
        #expect(!windows.contains { $0.windowID == privateWindow.session.windowID })
        #expect(try SessionRepository(persistence.database).windows(closed: true).isEmpty)
        #expect(try persistence.load().tabs.allSatisfy { $0.url?.host != "private.invalid" })
        let reopened = try #require(application.newPrivateWindow())
        #expect(try reopened.services?.permissions.decision(.camera, origin: "https://private.invalid", profileID: reopened.session.profileID) == .ask)
        for id in Array(application.stores.keys) { application.close(id) }
    }
    @Test func privateNavigationDoesNotRecordVisitsAndPrivateSuggestionsUseOnlyBookmarks() async throws {
        let application = BrowserApplicationContext(isolated: true)
        let store = try #require(application.newPrivateWindow())
        defer { for id in Array(application.stores.keys) { application.close(id) } }
        let services = try #require(store.services)
        let page = TabPage(services: services, profileID: store.session.profileID, tabID: UUID())
        defer { page.dispose() }
        page.webView.loadHTMLString("<title>Private fixture</title>", baseURL: URL(string: "https://private.invalid")!)
        for _ in 0..<100 {
            if page.webView.title == "Private fixture" && !page.webView.isLoading { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(page.webView.title == "Private fixture")
        page.webView(page.webView, didFinish: nil)
        #expect(try services.history.list(profileID: store.session.profileID).isEmpty)
        #expect(try application.services?.history.list(profileID: store.session.profileID).isEmpty == true)
        try application.services?.history.record(URL(string: "https://history-only.invalid")!, title: "History Only", profileID: store.session.profileID)
        let engine = SuggestionEngine()
        engine.update("history-only", bookmarks: BookmarkSuggestionProvider(repository: services.bookmarks, profileID: store.session.profileID), engine: .google, allowRemote: false)
        #expect(engine.results.count == 1 && engine.results[0].kind == .directSearch)
        #expect(!store.preferences.allowsRemoteSuggestions(isPrivate: true))
        #expect(store.preferences.allowsRemoteSuggestions(isPrivate: false))
        store.preferences.privateBraveSuggestions = true
        #expect(store.preferences.allowsRemoteSuggestions(isPrivate: true))
    }
}
