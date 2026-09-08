import Foundation
import Testing
import WebKit
import GRDB
@testable import Origami

@MainActor struct Phase2CleanupTests {
    @Test func profileMigrationCRUDAndColorPersistence() throws {
        let db = try DatabaseManager(migrate: false)
        try Migrations.make().migrate(db.queue, upTo: "v9_group_appearance")
        try db.queue.write { try $0.execute(sql: "INSERT INTO profiles VALUES (?,?,?,NULL)", arguments: [BrowserProfile.defaultID.uuidString, "Default", 0]) }
        try Migrations.make().migrate(db.queue)
        let repo = ProfileRepository(db)
        #expect(try repo.ensureDefault().name == "Personal")
        let work = try repo.create(name: "Work", color: .purple)
        try repo.update(work.id, name: "School", color: .orange)
        #expect(try repo.list().first { $0.id == work.id }?.color == .orange)
        #expect(try repo.list().first { $0.id == work.id }?.name == "School")
        var session = BrowserSession(); session.profileID = work.id
        try SessionRepository(db).save(session)
        try HistoryRepository(db).record(URL(string: "https://example.com")!, title: "Work", profileID: work.id)
        #expect(try HistoryRepository(db).list(profileID: BrowserProfile.defaultID).isEmpty)
        try repo.delete(work.id)
        #expect(try repo.list().count == 1)
        #expect(try SessionRepository(db).load(profileID: work.id) == nil)
        #expect(try HistoryRepository(db).list(profileID: work.id).isEmpty)
        #expect(throws: (any Error).self) { try repo.delete(BrowserProfile.defaultID) }
    }

    @Test func profileSwitchingKeepsPinsAndWebsiteStoresSeparate() throws {
        let app = BrowserApplicationContext(isolated: true)
        let personal = app.resolve(nil)
        let services = try #require(app.services)
        let work = try services.profiles.create(name: "Work", color: .green)
        let window = try app.switchProfile(work.id)
        for _ in 0..<6 { personal.togglePin(personal.newTab()) }
        let otherPersonal = app.newWindow(profileID: personal.session.profileID)
        otherPersonal.togglePin(otherPersonal.newTab())
        #expect(otherPersonal.session.tabs.allSatisfy { !$0.isPinned })
        window.togglePin(window.newTab())
        #expect(window.profilePinCount == 1)
        #expect(personal.profilePinCount == 6)
        #expect(try app.switchProfile(work.id) === window)
        #expect(try services.websiteStore(profileID: work.id).identifier != services.websiteStore(profileID: personal.session.profileID).identifier)
        #expect(try services.websiteStore(profileID: work.id).isPersistent)
        for id in Array(app.stores.keys) { app.close(id) }
    }

    @Test func profileSwitchReusesWindowStateAndRestoresTabs() throws {
        let app = BrowserApplicationContext(isolated: true)
        let personal = app.resolve(nil)
        let services = try #require(app.services)
        let work = try services.profiles.create(name: "Work", color: .purple)
        let personalTab = personal.newTab()
        personal.togglePin(personalTab)
        let state = BrowserWindowState()
        app.states[personal.session.windowID] = state
        var openedWindows = 0
        app.openWindow = { _ in openedWindows += 1 }

        let switched = try app.switchProfile(work.id, in: personal)
        #expect(openedWindows == 0)
        #expect(app.stores.count == 1)
        #expect(state.profileStore === switched)
        #expect(app.states[switched.session.windowID] === state)
        #expect(switched.session.tabs.allSatisfy { !$0.isPinned })
        let workTab = switched.newTab()

        let restored = try app.switchProfile(BrowserProfile.defaultID, in: switched)
        #expect(restored.session.tabs.contains { $0.id == personalTab && $0.isPinned })
        #expect(!restored.session.tabs.contains { $0.id == workTab })
        #expect(state.profileStore === restored)
        let workAgain = try app.switchProfile(work.id, in: restored)
        #expect(workAgain.session.tabs.contains { $0.id == workTab })
        #expect(openedWindows == 0)
        #expect(app.stores.count == 1)
        for id in Array(app.stores.keys) { app.close(id) }
    }

    @Test func compactSidebarFeatureFlagDefaultsOff() {
        #expect(!BrowserFeatureFlags.compactSidebarEnabled(environment: [:]))
        #expect(!BrowserFeatureFlags.compactSidebarEnabled(environment: ["ORIGAMI_ENABLE_COMPACT_SIDEBAR": "0"]))
        #expect(BrowserFeatureFlags.compactSidebarEnabled(environment: ["ORIGAMI_ENABLE_COMPACT_SIDEBAR": "1"]))
        #expect(BrowserFeatureFlags.sidebarBehavior(.compact, enabled: false) == .visible)
        #expect(BrowserFeatureFlags.sidebarBehavior(.visible, enabled: true) == .visible)
        #expect(BrowserFeatureFlags.sidebarBehavior(.compact, enabled: true) == .compact)
    }

    @Test func normalAndHardReloadRouteToDifferentPublicMethods() {
        let webView = ReloadSpy()
        TabPage.reloadWebView(webView, withoutCache: false)
        #expect(webView.normal == 1 && webView.hard == 0)
        TabPage.reloadWebView(webView, withoutCache: true)
        #expect(webView.normal == 1 && webView.hard == 1)
        let page = TabPage()
        #expect(page.webView.isInspectable)
        page.dispose()
    }

    @Test func compactTimingAndInsetsKeepContentStationary() {
        #expect(SidebarBehavior.allCases.count == 2)
        #expect(SidebarHoverState.Transition.reveal.delay == .milliseconds(160))
        #expect(SidebarHoverState.Transition.hide.delay == .milliseconds(350))
        for width: CGFloat in [220, 260, 320] {
            #expect(SidebarBehavior.compact.contentInset(layout: .vertical, width: width) == 0)
            #expect(SidebarBehavior.visible.contentInset(layout: .vertical, width: width) == width)
            #expect(SidebarBehavior.visible.contentInset(layout: .horizontal, width: width) == 0)
        }
    }
}

@MainActor private final class ReloadSpy: WKWebView {
    var normal = 0
    var hard = 0
    override func reload() -> WKNavigation? { normal += 1; return nil }
    override func reloadFromOrigin() -> WKNavigation? { hard += 1; return nil }
}
