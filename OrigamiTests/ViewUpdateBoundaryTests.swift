import AppKit
import WebKit
import Testing
@testable import Origami

@MainActor struct ViewUpdateBoundaryTests {
    @Test func delayedTabUpdateDoesNotBlurWebKitOrAnotherField() async throws {
        let store = BrowserStore()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let field = AddressField(frame: NSRect(x: 0, y: 560, width: 400, height: 30))
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 540), configuration: configuration)
        window.contentView?.addSubview(field)
        window.contentView?.addSubview(web)
        var view = Omnibox(store: store, allowRemote: false, tabID: UUID(), value: "https://example.invalid", focusRequest: UUID(), canFocus: false) { _, _ in }
        let coordinator = view.makeCoordinator()
        defer { coordinator.active = false }
        coordinator.field = field
        coordinator.lastTabID = view.tabID
        // The user has already clicked into WebKit, but SwiftUI's queued address
        // update still has the previous editing state (e.g. Split View selection).
        coordinator.editing = true
        #expect(window.makeFirstResponder(web))
        view.tabID = UUID()
        coordinator.parent = view
        coordinator.scheduleUpdate(field)
        try await Task.sleep(for: .milliseconds(30))
        #expect(window.firstResponder === web)
        #expect(!coordinator.editing)

        // A genuine address edit still ends when changing tabs.
        #expect(window.makeFirstResponder(field))
        coordinator.editing = true
        coordinator.parent.tabID = UUID()
        coordinator.scheduleUpdate(field)
        try await Task.sleep(for: .milliseconds(30))
        #expect(window.firstResponder !== field)
        #expect(field.currentEditor() == nil)
    }
    @Test func newTabSearchTypingUsesLocalAutocompleteAndActivatesWebsite() async throws {
        let store = BrowserStore()
        var query = ""
        var destination = ""
        var searchOnly = true
        let view = Omnibox(store: store, allowRemote: false, tabID: store.session.selectedTabID,
                           value: "", focusRequest: UUID(), canFocus: false,
                           placeholder: "Search the Web…", fontSize: 16, textChanged: { query = $0 }) {
            destination = $0; searchOnly = $1
        }
        let coordinator = view.makeCoordinator()
        let field = AddressField()
        coordinator.field = field
        coordinator.beginEditing(field)
        field.stringValue = "apple"
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        #expect(query == "apple")
        let apple = try #require(coordinator.suggestions.results.first { $0.input == "https://apple.com" })
        coordinator.activate(apple)
        #expect(destination.isEmpty)
        try await Task.sleep(for: .milliseconds(30))
        #expect(destination == "https://apple.com")
        #expect(!searchOnly)
        #expect(coordinator.suggestions.results.isEmpty)
        coordinator.active = false
    }

    @Test func editingCallbacksAreDeferredAndCoalesced() async throws {
        let store = BrowserStore()
        var events: [Bool] = []
        let view = Omnibox(store: store, allowRemote: false, tabID: nil, value: "", focusRequest: UUID(), editingChanged: { events.append($0) }) { _, _ in }
        let coordinator = view.makeCoordinator()
        coordinator.reportEditing(true)
        coordinator.reportEditing(false)
        #expect(events.isEmpty)
        try await Task.sleep(for: .milliseconds(20))
        #expect(events == [false])
        coordinator.reportEditing(true)
        coordinator.active = false
        try await Task.sleep(for: .milliseconds(20))
        #expect(events == [false])
    }

    @Test func readingVisiblePageDoesNotCreateOrMutateBrowserState() {
        let store = BrowserStore()
        let session = store.session
        #expect(store.visiblePage == nil)
        #expect(store.pages.isEmpty)
        #expect(store.session == session)
        store.prepareSelectedPage()
        let page = store.visiblePage
        #expect(page != nil)
        store.prepareSelectedPage()
        #expect(store.visiblePage === page)
        #expect(store.pages.count == 1)
        store.pages.values.forEach { $0.dispose() }
    }

    @Test func scheduledOmniboxUpdateUsesLatestTabAndDoesNotPublishInline() async throws {
        let store = BrowserStore()
        var events: [Bool] = []
        let field = AddressField()
        var view = Omnibox(store: store, allowRemote: false, tabID: UUID(), value: "https://first.example", focusRequest: UUID(), canFocus: false, editingChanged: { events.append($0) }) { _, _ in }
        let coordinator = view.makeCoordinator()
        coordinator.scheduleUpdate(field)
        view.tabID = UUID(); view.value = "https://second.example"
        coordinator.parent = view
        coordinator.scheduleUpdate(field)
        #expect(events.isEmpty)
        #expect(coordinator.lastTabID == nil)
        try await Task.sleep(for: .milliseconds(20))
        #expect(coordinator.lastTabID == view.tabID)
        #expect(field.stringValue == "second.example")
        coordinator.active = false
    }
    @Test func returnDefersNavigationAndDropsSubmissionAfterTabChange() async throws {
        let store = BrowserStore()
        var submitted: [String] = []
        let view = Omnibox(store: store, allowRemote: false, tabID: UUID(), value: "", focusRequest: UUID()) { submitted.append($0); _ = $1 }
        let coordinator = view.makeCoordinator()
        let field = AddressField(), editor = NSTextView()
        coordinator.field = field
        field.stringValue = "https://example.com/article"
        #expect(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(submitted.isEmpty)
        field.stringValue = "changed after Return"
        try await Task.sleep(for: .milliseconds(30))
        #expect(submitted == ["https://example.com/article"])
        #expect(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        coordinator.parent.tabID = UUID()
        try await Task.sleep(for: .milliseconds(30))
        #expect(submitted.count == 1)
        coordinator.active = false
    }

}
