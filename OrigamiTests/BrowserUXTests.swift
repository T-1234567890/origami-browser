import Foundation
import GRDB
import Testing
@testable import Origami

@MainActor struct BrowserUXTests {
    @Test func closingEitherSplitMemberKeepsTheOtherSelected() throws {
        for closeLeft in [true, false] {
            let store = BrowserStore()
            defer { store.pages.values.forEach { $0.dispose() } }
            let left = try #require(store.session.selectedTabID)
            let outside = store.newTab(), right = store.newTab()
            store.select(left); store.splitWith(right)
            let closing = closeLeft ? left : right, remaining = closeLeft ? right : left
            store.select(closing)
            let remainingPage = store.pages[remaining]
            store.close(closing)
            #expect(store.session.split == nil)
            #expect(store.session.selectedTabID == remaining)
            #expect(Set(store.session.tabs.map(\.id)) == Set([outside, remaining]))
            #expect(store.pages[remaining] === remainingPage)
        }
    }

    @Test func splitTabsShareOneEntryAndDetachWithoutLosingPages() throws {
        let store = BrowserStore()
        defer { store.pages.values.forEach { $0.dispose() } }
        let left = try #require(store.session.selectedTabID)
        let right = store.newTab(), outside = store.newTab()
        store.select(left); store.splitWith(right)
        let leftPage = store.pages[left], rightPage = store.pages[right]
        #expect(store.session.tabStripItems.map(\.id) == [left, outside])
        store.select(outside)
        #expect(store.session.split != nil && store.session.activeSplit == nil)
        store.select(right)
        #expect(store.session.activeSplit?.right == right)
        store.detachSplitTab(right, target: .end)
        #expect(store.session.split == nil)
        #expect(store.session.tabStripItems.map(\.id) == [left, outside, right])
        #expect(store.session.selectedTabID == right)
        #expect(store.pages[left] === leftPage && store.pages[right] === rightPage)
    }

    @Test func groupPaletteRejectsReservedColorsAndRepairsLegacyGroups() {
        #expect(!TabGroupColor.selectable.contains(.accent))
        #expect(!TabGroupColor.selectable.contains(.blue))
        var session = BrowserSession()
        session.groups = [TabGroup(name: "Default"), TabGroup(name: "Blue", color: .blue)]
        session.normalize()
        #expect(session.groups.allSatisfy { $0.color == .purple })
        let store = BrowserStore(session: session)
        let id = store.createGroup(name: "New")
        #expect(store.session.groups.last?.color == .purple)
        store.setGroupColor(id, color: .blue)
        #expect(store.session.groups.last?.color == .purple)
        store.setGroupColor(id, color: .green)
        #expect(store.session.groups.last?.color == .green)
    }

    @Test func draggingGroupMovesMembersTogetherWithoutChangingMembership() {
        let store = BrowserStore()
        let outside = store.session.tabs[0].id
        let first = store.newTab(), second = store.newTab()
        let group = store.createGroup(name: "Work", tabID: first)
        store.setGroup(second, groupID: group)
        store.toggleGroup(group)
        store.dropGroup(group, target: .tab(outside, after: false))
        #expect(store.session.tabs.map(\.id) == [first, second, outside])
        #expect(store.session.tabs.last?.groupID == nil)
        #expect(store.session.groups.first?.isCollapsed == true)
        store.dropGroup(group, target: .tab(first, after: true))
        #expect(store.session.tabs.map(\.id) == [first, second, outside])
        store.dropGroup(group, target: .end)
        #expect(store.session.tabs.map(\.id) == [outside, first, second])
    }

    @Test func draggingEmptyGroupPreservesAnchorAndOtherGroups() {
        let store = BrowserStore()
        let tab = store.session.tabs[0].id
        let empty = store.createGroup(name: "Empty")
        let other = store.createGroup(name: "Other", tabID: tab)
        store.dropGroup(empty, target: .group(other))
        #expect(store.session.tabStripItems.map(\.id) == [empty, other, tab])
        #expect(store.session.tabs[0].groupID == other)
    }

    @Test func recentlyClosedRejectsBuiltInPagesIncludingLegacyRows() throws {
        let store = BrowserStore()
        store.close(store.session.tabs[0].id)
        for page in [InternalPage.newtab, .history, .bookmarks, .settings] {
            let id = store.newTab(url: page.url); store.close(id)
        }
        #expect(store.recentlyClosed.isEmpty)
        let id = store.newTab(url: URL(string: "https://example.com")!); store.close(id)
        #expect(store.recentlyClosed.count == 1)
        let db = try DatabaseManager(); _ = try ProfileRepository(db).ensureDefault()
        try SessionRepository(db).save(store.session, recentlyClosed: store.recentlyClosed)
        try db.queue.write { try $0.execute(sql: "UPDATE recently_closed SET url='origami://history'") }
        #expect(try RecentlyClosedRepository(db).list(profileID: store.session.profileID, windowID: store.session.windowID).isEmpty)
    }
    @Test func onlyDroppingOnGroupTitleJoinsGroup() {
        let store = BrowserStore()
        let a = store.session.tabs[0].id, b = store.newTab(), c = store.newTab()
        let group = store.createGroup(name: "Work", tabID: b)
        store.setGroup(c, groupID: group)
        store.dragTab(a, onto: b)
        #expect(store.session.tabs.first { $0.id == a }?.groupID == nil)
        store.finishTabDrag(a, groupID: group)
        #expect(store.session.tabs.first { $0.id == a }?.groupID == group)
        #expect(store.session.tabs.first { $0.id == b }?.groupID == group)
        #expect(store.session.tabs.first { $0.id == c }?.groupID == group)
        let outside = store.newTab()
        store.dragTab(a, onto: outside)
        store.finishTabDrag(a, groupID: nil)
        #expect(store.session.tabs.first { $0.id == a }?.groupID == nil)
        #expect(store.session.tabs.first { $0.id == outside }?.groupID == nil)
        let empty = store.createGroup(name: "Empty")
        store.setGroup(a, groupID: empty)
        #expect(store.session.tabs.first { $0.id == a }?.groupID == empty)
        store.setGroup(a, groupID: nil)
        #expect(store.session.tabs.first { $0.id == a }?.groupID == nil)
    }
    @Test func blankTabsCanStayBelowGroupsAndCollapsedGroupsHideOnlyMembers() {
        let store = BrowserStore()
        let member = store.session.tabs[0].id
        let group = store.createGroup(name: "Work", tabID: member)
        let blank = store.newTab()
        let items = store.session.tabStripItems.map(\.id)
        #expect(items == [group, member, blank])
        store.toggleGroup(group)
        #expect(store.session.tabStripItems.map(\.id) == [group, blank])
        store.toggleGroup(group)
        store.dragTab(blank, onto: member)
        #expect(store.session.tabs.first?.id == blank)
        #expect(store.session.tabs.first?.groupID == nil)
        store.finishTabDrag(blank, groupID: nil, atEnd: true)
        #expect(store.session.tabStripItems.map(\.id) == [group, member, blank])
        let empty = store.createGroup(name: "Empty")
        let next = store.newTab()
        #expect(store.session.tabStripItems.map(\.id).suffix(2) == [empty, next])
    }

    @Test func groupColorsAndOrderSurvivePersistenceAndLegacyMigration() throws {
        let db = try DatabaseManager(migrate: false)
        try Migrations.make().migrate(db.queue, upTo: "v8_site_rule_timestamps")
        let profile = try ProfileRepository(db).ensureDefault()
        let sessionID = UUID(), windowID = UUID(), groupID = UUID()
        try db.queue.write { database in
            try database.execute(sql: "INSERT INTO browser_sessions VALUES (?,?,0)", arguments: [sessionID.uuidString, profile.id.uuidString])
            try database.execute(sql: "INSERT INTO windows(id,session_id) VALUES (?,?)", arguments: [windowID.uuidString, sessionID.uuidString])
            try database.execute(sql: "INSERT INTO tab_groups VALUES (?,?,?,0,0)", arguments: [groupID.uuidString, windowID.uuidString, "Existing"])
        }
        try Migrations.make().migrate(db.queue)
        var session = try #require(try SessionRepository(db).load(profileID: profile.id))
        #expect(session.groups.first?.name == "Existing")
        #expect(session.groups.first?.color == .purple)
        let store = BrowserStore(session: session)
        store.setGroupColor(groupID, color: .orange)
        let member = store.newTab(groupID: groupID)
        let blank = store.newTab()
        session = store.session
        try SessionRepository(db).save(session)
        let restored = try #require(try SessionRepository(db).load(profileID: profile.id))
        #expect(restored.groups.first?.color == .orange)
        #expect(restored.tabStripItems.map(\.id) == [groupID, member, blank])
        let oldJSON = Data("{\"id\":\"\(UUID().uuidString)\",\"name\":\"Legacy\",\"isCollapsed\":false}".utf8)
        #expect(try JSONDecoder().decode(TabGroup.self, from: oldJSON).color == nil)
    }

    @Test func dropInsertsOneTabWithoutSwappingOtherTabsOrImplicitlyJoining() {
        let store = BrowserStore()
        let a = store.session.tabs[0].id, b = store.newTab(), c = store.newTab(), d = store.newTab()
        let group = store.createGroup(name: "Work", tabID: b)
        store.setGroup(c, groupID: group)
        store.dropTab(a, target: .tab(c, after: true))
        #expect(store.session.tabs.map(\.id) == [b, c, a, d])
        #expect(store.session.tabs.first { $0.id == a }?.groupID == nil)
        store.dropTab(c, target: .tab(b, after: false))
        #expect(store.session.tabs.map(\.id) == [c, b, a, d])
        #expect(store.session.tabs.first { $0.id == c }?.groupID == group)
        store.dropTab(a, target: .group(group))
        #expect(store.session.tabs.first { $0.id == a }?.groupID == group)
        store.dropTab(a, target: .end)
        #expect(store.session.tabs.last?.id == a && store.session.tabs.last?.groupID == nil)
    }

    @Test func pinLimitRejectsSeventhPinAndRestorationKeepsEveryTab() throws {
        let store = BrowserStore()
        for _ in 0..<7 { store.newTab() }
        let ids = store.session.tabs.map(\.id)
        for id in ids.prefix(6) { store.togglePin(id) }
        store.togglePin(ids[6])
        #expect(store.session.tabs.filter(\.isPinned).count == 6)
        #expect(store.session.tabs.first { $0.id == ids[6] }?.isPinned == false)
        store.togglePin(ids[0]); store.togglePin(ids[6])
        #expect(store.session.tabs.filter(\.isPinned).count == 6)
        #expect(store.session.tabs.first { $0.id == ids[6] }?.isPinned == true)
        var legacy = store.session
        for index in legacy.tabs.indices { legacy.tabs[index].isPinned = true }
        legacy.normalize()
        #expect(legacy.tabs.count == ids.count)
        #expect(Set(legacy.tabs.map(\.id)) == Set(ids))
        #expect(legacy.tabs.filter(\.isPinned).count == 6)
        let db = try DatabaseManager(); _ = try ProfileRepository(db).ensureDefault()
        try SessionRepository(db).save(legacy)
        let restored = try #require(try SessionRepository(db).load(profileID: legacy.profileID))
        #expect(restored.tabs.count == ids.count && restored.tabs.filter(\.isPinned).count == 6)
    }

}
