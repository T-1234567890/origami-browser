import Foundation
import Testing
@testable import Origami

@MainActor
struct NativeDestinationTests {
    @Test func mixedHistoryTruncatesForwardEntries() {
        var history = TabDestinationHistory()
        let first = history.visit(InternalPage.newtab.url)
        let website = history.visit(URL(string: "https://example.com")!)
        history.visit(InternalPage.history.url)
        #expect(history.move(-1) == website)
        history.visit(InternalPage.settings.url)
        #expect(!history.canGoForward)
        #expect(history.entries.count == 3)
        history.select(first.id)
        #expect(!history.canGoBack)
        #expect(history.move(-1) == nil)
        #expect(history.current == first)
    }

    @Test func reopeningWelcomePreservesBrowsingData() async throws {
        let store = BrowserStore()
        defer { store.pages.values.forEach { $0.dispose() } }
        let previous = store.session.tabs
        let services = try #require(store.services)
        let bookmark = try services.bookmarks.addUnique(url: URL(string: "https://example.com")!, title: "Saved", profileID: store.session.profileID)
        store.openInternal(.welcome)
        #expect(store.selectedPage?.nativePage == .welcome)
        #expect(store.session.tabs.count == previous.count + 1)
        #expect(previous.allSatisfy { old in store.session.tabs.contains(where: { $0.id == old.id }) })
        #expect(try services.bookmarks.list(profileID: store.session.profileID).contains { $0.id == bookmark })
    }

    @Test func finishingWelcomeAppliesChoicesAndKeepsExistingTabs() async throws {
        let store = BrowserStore()
        defer { store.pages.values.forEach { $0.dispose() } }
        let existing = store.session.tabs.map(\.id)
        store.openInternal(.welcome)
        let id = try #require(store.session.selectedTabID)
        _ = try await store.handleInternal("settings.write", params: ["layout": "vertical", "search": "bing", "restore": true, "privacy": "strict"], tabID: id)
        _ = try await store.handleInternal("onboarding.complete", params: [:], tabID: id)
        for _ in 0..<20 {
            if !store.isShowingWelcome { break }
            await Task.yield()
        }
        #expect(!store.isShowingWelcome)
        #expect(store.selectedPage?.nativePage == .newtab)
        #expect(store.session.layout == .vertical && store.session.searchEngine == .bing)
        #expect(store.preferences.onboardingComplete)
        #expect(existing.allSatisfy { id in store.session.tabs.contains { $0.id == id } })
    }

    @Test func nativeConfirmationCanBeCancelled() async {
        let store = BrowserStore()
        let tabID = store.session.selectedTabID!
        _ = store.selectedPage
        defer { store.pages.values.forEach { $0.dispose() } }
        let request = Task { await store.confirm("Delete?", tabID: tabID) }
        await Task.yield()
        store.resolveConfirmation(false)
        #expect(await request.value == false)
        #expect(store.confirmationMessage == nil)
    }

    @Test(arguments: InternalPage.allCases)
    func everyNativeDestinationHasAnExactRoute(_ page: InternalPage) {
        #expect(InternalRoute.page(for: page.url) == page)
        #expect(!page.title.isEmpty)
        #expect(InternalRoute.page(for: URL(string: page.url.absoluteString + "/unexpected")!) == nil)
    }
}
