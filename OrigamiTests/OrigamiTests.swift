import Foundation
import Testing
@testable import Origami

@MainActor
struct OrigamiTests {
    @Test(arguments: ["apple.com", "example.com/path?q=hello#part", "localhost:8080", "127.0.0.1:3000", "[::1]:8080"])
    func domainRouting(_ input: String) {
        #expect(OmniboxRouter.destination(for: input, engine: .google)?.absoluteString == "https://" + input)
    }
    @Test(arguments: ["swift actor isolation", "hello world.com", "user@example.com", "javascript:alert(1)", "file:///etc/passwd", "hello", "hello:world"])
    func searchRouting(_ input: String) {
        #expect(OmniboxRouter.destination(for: input, engine: .bing) == SearchEngine.bing.searchURL(for: input))
    }
    @Test func explicitURLAndEmpty() {
        #expect(OmniboxRouter.destination(for: " https://github.com/ \n", engine: .google) == URL(string: "https://github.com/"))
        #expect(OmniboxRouter.destination(for: "http://localhost:8080/path", engine: .google)?.scheme == "http")
        #expect(OmniboxRouter.destination(for: " \n", engine: .google) == nil)
    }
    @Test(arguments: SearchEngine.allCases)
    func searchEncoding(_ engine: SearchEngine) {
        let query = "Swift & WebKit + 中文 #? / 😀"
        let components = URLComponents(url: engine.searchURL(for: query), resolvingAgainstBaseURL: false)
        #expect(components?.scheme == "https")
        #expect(components?.queryItems?.first(where: { $0.name == "q" })?.value == query)
        #expect(components?.fragment == nil)
    }
    @Test func legacySessionIsImportedOnceIntoSQLite() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacyURL = directory.appending(path: "session.json")
        let legacy = """
        {"version":1,"tabs":[],"groups":[],"layout":"vertical","searchEngine":"brave","restoreSession":true}
        """
        try Data(legacy.utf8).write(to: legacyURL)
        let persistence = SessionStore(fileURL: directory.appending(path: "browser.sqlite"), legacyURL: legacyURL)
        let imported = try persistence.load()
        #expect(imported.tabs.isEmpty)
        #expect(imported.layout == .vertical)
        #expect(imported.searchEngine == .brave)
        try Data("corrupt legacy file after successful import".utf8).write(to: legacyURL)
        #expect(try persistence.load() == imported)
    }

    @Test func selectedProfileRestoresItsOwnSession() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = SessionStore(fileURL: directory.appending(path: "browser.sqlite"))
        var initial = try persistence.load()
        initial.normalize()
        try persistence.save(initial)
        let profile = try ProfileRepository(persistence.database).create(name: "Work")
        var work = BrowserSession()
        work.profileID = profile.id
        work.tabs = [BrowserTab(url: URL(string: "https://example.com/work"))]
        work.normalize()
        try persistence.save(work)
        #expect(try persistence.load().profileID == profile.id)
        #expect(try persistence.load().tabs.first?.url == work.tabs.first?.url)
        #expect(try SessionRepository(persistence.database).load(profileID: initial.profileID)?.windowID == initial.windowID)
    }

    @Test func tabLifecycle() throws {
        let store = BrowserStore()
        let initial = try #require(store.selectedTab?.id)
        let second = store.newTab(url: URL(string: "https://apple.com"))
        #expect(store.session.tabs.count == 2)
        #expect(store.session.selectedTabID == second)
        store.close(second)
        #expect(store.session.selectedTabID == initial)
        store.reopenClosedTab()
        #expect(store.session.selectedTabID == second)
        store.duplicate(second)
        #expect(store.session.tabs.count == 3)
        #expect(store.selectedTab?.id != second)
        #expect(store.selectedTab?.url == URL(string: "https://apple.com"))
    }
    @Test func closeLastTabAndInvalidOperations() throws {
        let store = BrowserStore()
        store.close(try #require(store.selectedTab?.id))
        #expect(store.session.tabs.isEmpty)
        #expect(store.selectedTab == nil)
        #expect(store.selectedPage == nil)
        let snapshot = store.session
        store.close(UUID()); store.select(UUID()); store.move(UUID(), before: UUID())
        #expect(store.session == snapshot)
    }
    @Test func reopenAndCreateAfterClosingLastTab() throws {
        let store = BrowserStore()
        store.session.tabs[0].url = URL(string: "https://example.com")
        let original = try #require(store.selectedTab?.id)
        store.close(original)
        store.cycleTab(1)
        #expect(store.session.selectedTabID == nil)
        store.reopenClosedTab()
        #expect(store.session.tabs.count == 1)
        #expect(store.session.selectedTabID == original)
        store.close(original)
        store.navigate("  ")
        #expect(store.session.tabs.isEmpty)
        let newID = store.newTab()
        #expect(store.session.tabs.count == 1)
        #expect(store.session.selectedTabID == newID)
        #expect(newID != original)
    }

    @Test func emptySessionRestoresWithoutReplacementTab() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = SessionStore(fileURL: directory.appending(path: "browser.sqlite"))
        let store = BrowserStore(persistence: persistence)
        store.setLayout(.vertical)
        store.close(try #require(store.selectedTab?.id))
        let restored = BrowserStore(persistence: persistence)
        #expect(restored.session.tabs.isEmpty)
        #expect(restored.session.selectedTabID == nil)
        #expect(restored.session.layout == .vertical)
    }

    @Test func reorderingAndPins() throws {
        let store = BrowserStore()
        let first = try #require(store.selectedTab?.id)
        let second = store.newTab()
        let third = store.newTab()
        store.move(third, before: first)
        #expect(store.session.tabs.map(\.id) == [third, first, second])
        store.togglePin(second)
        #expect(store.session.tabs.first?.id == second)
        store.move(first, before: second)
        #expect(store.session.tabs.first?.id == second)
        store.moveBy(first, offset: -1)
        #expect(store.session.tabs.map(\.id) == [second, first, third])
        store.togglePin(second)
        #expect(store.session.tabs.allSatisfy { !$0.isPinned })
    }
    @Test func swappingTabsExchangesVisiblePositions() throws {
        let store = BrowserStore()
        let first = try #require(store.selectedTab?.id)
        let middle = store.newTab()
        let last = store.newTab()
        let group = store.createGroup(name: "Work", tabID: last)
        store.swapTabs(first, with: last)
        #expect(store.orderedTabs.map(\.id) == [last, middle, first])
        #expect(store.session.tabs.first(where: { $0.id == first })?.groupID == group)
        #expect(store.session.tabs.first(where: { $0.id == last })?.groupID == nil)
        store.togglePin(last)
        let snapshot = store.session
        store.swapTabs(last, with: first)
        #expect(store.session == snapshot)
        store.swapTabs(first, with: first)
        store.swapTabs(UUID(), with: first)
        #expect(store.session == snapshot)
    }

    @Test func groups() throws {
        let store = BrowserStore()
        let tab = try #require(store.selectedTab?.id)
        let group = store.createGroup(name: "Work", tabID: tab)
        #expect(store.selectedTab?.groupID == group)
        store.toggleGroup(group)
        #expect(store.session.groups.first?.isCollapsed == true)
        store.select(tab)
        #expect(store.session.groups.first?.isCollapsed == false)
        store.togglePin(tab)
        #expect(store.selectedTab?.groupID == nil)
        store.setGroup(tab, groupID: group)
        #expect(store.selectedTab?.isPinned == false)
        store.renameGroup(group, name: "Research")
        #expect(store.session.groups.first?.name == "Research")
        store.removeGroup(group)
        #expect(store.selectedTab?.groupID == nil)
    }
    @Test func sessionRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = SessionStore(fileURL: directory.appending(path: "browser.sqlite"))
        let store = BrowserStore(persistence: persistence)
        let first = try #require(store.selectedTab?.id)
        store.togglePin(first)
        let second = store.newTab(url: URL(string: "https://example.com/path"))
        let group = store.createGroup(name: "Work", tabID: second)
        store.toggleGroup(group)
        store.setLayout(.vertical)
        store.setSearchEngine(.brave)
        store.save()
        let restored = try persistence.load()
        #expect(restored == store.session)
        #expect(restored.selectedTabID == second)
        #expect(restored.layout == .vertical)
        #expect(restored.groups.first?.isCollapsed == true)
        store.setRestoreSession(false)
        let fresh = try persistence.load()
        #expect(fresh.tabs.count == 2)
        #expect(fresh.tabs.first?.id == first)
        #expect(fresh.tabs.first?.isPinned == true)
        #expect(fresh.tabs.last?.url == nil)
        #expect(fresh.selectedTabID == fresh.tabs.last?.id)
        #expect(!fresh.tabs.contains { $0.id == second })
        #expect(fresh.groups.isEmpty)
        #expect(fresh.layout == .vertical)
        #expect(fresh.searchEngine == .brave)
    }
    @Test func sessionDoesNotStoreEmbeddedContentOrCredentials() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = SessionStore(fileURL: directory.appending(path: "browser.sqlite"))
        var session = BrowserSession(tabs: [
            BrowserTab(url: URL(string: "data:text/html,private-content")),
            BrowserTab(url: URL(string: "https://user:secret@example.com/page"))
        ])
        session.normalize()
        try persistence.save(session)
        let restored = try persistence.load()
        #expect(restored.tabs[0].url == nil)
        #expect(restored.tabs[1].url?.absoluteString == "https://example.com/page")
        let text = try Data(contentsOf: persistence.fileURL)
        #expect(text.range(of: Data("private-content".utf8)) == nil)
        #expect(text.range(of: Data("secret".utf8)) == nil)
    }
    @Test func unreadableSessionIsReported() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let persistence = SessionStore(fileURL: directory.appending(path: "browser.sqlite"))
        try Data("invalid JSON".utf8).write(to: persistence.fileURL)
        #expect(throws: (any Error).self) { try persistence.load() }
        let store = BrowserStore(persistence: persistence)
        #expect(store.persistenceError != nil)
        #expect(store.selectedTab != nil)
    }
    @Test func malformedSessionNormalization() {
        let tab = BrowserTab(groupID: UUID())
        var session = BrowserSession(tabs: [tab, tab], selectedTabID: UUID())
        session.normalize()
        #expect(session.tabs.count == 1)
        #expect(session.selectedTabID == tab.id)
        #expect(session.tabs[0].groupID == nil)
    }
    @Test func twentyIndependentWebViews() throws {
        let store = BrowserStore()
        for _ in 1..<20 { store.newTab() }
        let ids = store.session.tabs.map(\.id)
        let views = ids.map { store.page(for: $0).webView }
        #expect(Set(views.map(ObjectIdentifier.init)).count == 20)
        for (index, id) in ids.enumerated() {
            store.select(id)
            #expect(store.selectedPage?.webView === views[index])
        }
        store.setLayout(.vertical)
        store.setLayout(.horizontal)
        #expect(store.page(for: ids[0]).webView === views[0])
        ids.forEach { store.close($0) }
    }
}
