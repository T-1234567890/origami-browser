import Testing
import Foundation
import WebKit
@testable import Origami

@MainActor struct BrowsingRefinementTests {
    @Test func printingIsAllowedByTheSandbox() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Configuration/Origami.entitlements"))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        #expect(plist?["com.apple.security.print"] as? Bool == true)
    }
    @Test(.timeLimit(.minutes(1))) func hoverBridgeIsIsolatedAndClosingPreservesUnderlyingTab() async throws {
        let store = BrowserStore()
        let id = try #require(store.session.selectedTabID)
        store.pages[id]?.dispose()
        let page = TabPage(tabID: id)
        store.pages[id] = page; store.bind(page, to: id)
        defer { store.dismissPeek(); store.pages.values.forEach { $0.dispose() } }
        page.webView.loadHTMLString("<title>Link Preview</title><a href='https://example.com/next'>Next</a>", baseURL: URL(string: "https://example.com"))
        let deadline = Date().addingTimeInterval(15)
        while page.webView.isLoading || page.webView.title != "Link Preview" {
            guard Date() < deadline else { throw RepositoryError.invalidInput }
            try await Task.sleep(for: .milliseconds(50))
        }
        let bridge = try await page.webView.callAsyncJavaScript("return typeof window.webkit?.messageHandlers?.origamiLinkHover;", arguments: [:], in: nil, contentWorld: .page) as? String
        #expect(bridge == "undefined")
        let count = store.session.tabs.count
        page.linkPeekObserver.changed?(URL(string: "https://example.com/next"), CGPoint(x: 0.2, y: 0.4))
        #expect(store.peekSourceID == page.tabID)
        #expect(store.peekAnchor == CGPoint(x: 0.2, y: 0.4))
        page.linkPeekObserver.changed?(nil, .zero)
        #expect(store.peekPage == nil && store.peekSourceID == nil)
        #expect(store.session.tabs.count == count && store.selectedPage === page)
    }
}
