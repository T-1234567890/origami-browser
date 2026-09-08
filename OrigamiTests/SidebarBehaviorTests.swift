import Foundation
import Testing
@testable import Origami

struct SidebarBehaviorTests {
    @Test func behaviorPersistsAndFallsBackSafely() throws {
        let suite = "Origami.SidebarTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = BrowserPreferences(defaults: defaults)
        #expect(preferences.sidebarBehavior == .visible)
        for behavior in SidebarBehavior.allCases {
            preferences.sidebarBehavior = behavior
            #expect(BrowserPreferences(defaults: defaults).sidebarBehavior == behavior)
        }
        defaults.set("hidden", forKey: "browser.sidebarBehavior")
        #expect(preferences.sidebarBehavior == .visible)
        defaults.set("unknown", forKey: "browser.sidebarBehavior")
        #expect(preferences.sidebarBehavior == .visible)
    }
    @Test func briefEdgeVisitsDoNotReveal() {
        var hover = SidebarHoverState()
        hover.edgeChanged(true)
        #expect(!hover.isRevealed)
        #expect(hover.pending == .reveal)
        hover.edgeChanged(false)
        hover.finish(.reveal)
        #expect(!hover.isRevealed)
        #expect(hover.pending == nil)
    }
    @Test func revealAndHideAreDelayedAndReentryCancelsHiding() {
        var hover = SidebarHoverState()
        hover.edgeChanged(true); hover.finish(.reveal)
        #expect(hover.isRevealed)
        hover.sidebarChanged(true); hover.edgeChanged(false)
        hover.sidebarChanged(false)
        #expect(hover.isRevealed)
        #expect(hover.pending == .hide)
        hover.sidebarChanged(true); hover.finish(.hide)
        #expect(hover.isRevealed)
        hover.sidebarChanged(false); hover.finish(.hide)
        #expect(!hover.isRevealed)
    }
    @Test func resetCancelsPendingWorkAndEditingKeepsOverlayAvailable() {
        var hover = SidebarHoverState()
        hover.edgeChanged(true); hover.reset(); hover.finish(.reveal)
        #expect(!hover.isRevealed)
        hover.revealForKeyboard(); hover.interactionChanged(true)
        hover.sidebarChanged(false); hover.finish(.hide)
        #expect(hover.isRevealed)
        hover.interactionChanged(false); hover.finish(.hide)
        #expect(!hover.isRevealed)
    }
    @Test func compactNeverReservesWebContentSpace() {
        for width: CGFloat in [220, 240, 320] {
            #expect(SidebarBehavior.visible.contentInset(layout: .vertical, width: width) == width)
            for behavior in [SidebarBehavior.compact] {
                #expect(behavior.contentInset(layout: .vertical, width: width) == 0)
            }
            for behavior in SidebarBehavior.allCases {
                #expect(behavior.contentInset(layout: .horizontal, width: width) == 0)
            }
        }
    }
    @MainActor @Test func restoringSidebarIsExplicitAndHorizontalShortcutIsInactive() {
        let store = BrowserStore()
        if !BrowserFeatureFlags.compactSidebar {
            store.preferences.sidebarBehavior = .compact
            #expect(store.sidebarBehavior == .visible)
            store.setLayout(.vertical)
            store.toggleSidebar()
            #expect(store.sidebarBehavior == .visible)
            store.setSidebarBehavior(.compact)
            #expect(store.sidebarBehavior == .visible)
            return
        }
        store.setSidebarBehavior(.compact)
        store.toggleSidebar()
        #expect(store.sidebarBehavior == .compact)
        store.setLayout(.vertical)
        #expect(store.sidebarBehavior == .compact)
        store.toggleSidebar()
        #expect(store.sidebarBehavior == .visible)
        store.toggleSidebar()
        #expect(store.sidebarBehavior == .compact)
        store.focusOmnibox()
        #expect(store.sidebarBehavior == .compact)
        store.expandSidebarFromEmptySpace()
        #expect(store.sidebarBehavior == .visible)
        store.setSidebarBehavior(.compact)
        store.setLayout(.horizontal); store.setLayout(.vertical)
        #expect(store.sidebarBehavior == .compact)
    }
}
