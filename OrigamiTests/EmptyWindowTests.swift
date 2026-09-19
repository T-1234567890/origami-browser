import AppKit
import Testing
@testable import Origami

@MainActor struct EmptyWindowTests {
    private final class Window: NSWindow {
        var closes = 0
        override func close() { closes += 1 }
    }
    @Test func closingLastTabClosesOnlyItsOwnWindow() async throws {
        let app = BrowserApplicationContext(isolated: true)
        let first = app.resolve(nil), second = app.newWindow()
        defer { for id in Array(app.stores.keys) { app.close(id) } }
        let a = Window(), b = Window()
        let firstState = BrowserWindowState(), secondState = BrowserWindowState()
        firstState.window = a; secondState.window = b
        app.states[first.session.windowID] = firstState
        app.states[second.session.windowID] = secondState
        for tab in first.session.tabs { first.close(tab.id) }
        await Task.yield()
        try await Task.sleep(for: .milliseconds(30))
        #expect(a.closes == 1)
        #expect(b.closes == 0)
        #expect(!second.session.tabs.isEmpty)
    }
    @Test func pendingCloseWaitsForAttachmentAndCancelsIfTabAdded() {
        let app = BrowserApplicationContext(isolated: true), state = BrowserWindowState()
        let store = app.resolve(nil)
        defer { for id in Array(app.stores.keys) { app.close(id) } }
        store.session.tabs = []
        state.closeIfEmpty(store)
        let window = Window()
        state.attach(window, layout: .vertical, savedFrame: nil)
        #expect(window.closes == 1)
        state.attach(nil, layout: .vertical, savedFrame: nil)
        #expect(state.window === window)
        state.closeIfEmpty(store)
        store.newTab()
        state.attach(window, layout: .vertical, savedFrame: nil)
        #expect(window.closes == 1)
    }
}
