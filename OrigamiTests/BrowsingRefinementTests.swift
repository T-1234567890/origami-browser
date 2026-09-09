import Testing
import Foundation
import Security
import WebKit
@testable import Origami

@MainActor struct BrowsingRefinementTests {
    @Test func feedDiscoveryIncludesVisibleAndDynamicallyAddedLinks() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        defer { webView.stopLoading() }
        webView.loadHTMLString("""
        <html><head><title>Feed fixture</title>
        <link rel="alternate" type="application/atom+xml" href="/atom.xml">
        </head><body>
        <a href="/forums/rss?topic=distribution" aria-label="RSS for tag"><span>◉</span></a>
        <a href="/atom.xml#duplicate">Atom feed</a>
        <a href="javascript:alert(1)">RSS</a>
        <a href="https://user:password@example.com/rss">RSS</a>
        <a href="/articles/normal">A normal article</a>
        </body></html>
        """, baseURL: URL(string: "https://example.com/topics/"))
        let deadline = Date().addingTimeInterval(15)
        while webView.title != "Feed fixture" || webView.isLoading {
            guard Date() < deadline else { throw RepositoryError.invalidInput }
            try await Task.sleep(for: .milliseconds(50))
        }
        let first = try await webView.callAsyncJavaScript(FeedDiscovery.script, arguments: [:], in: nil, contentWorld: .defaultClient) as? [String]
        #expect(first == ["https://example.com/atom.xml", "https://example.com/forums/rss?topic=distribution"])
        _ = try await webView.evaluateJavaScript("const a=document.createElement('a');a.href='/updates/feed';a.textContent='Subscribe';document.body.append(a)")
        let updated = try await webView.callAsyncJavaScript(FeedDiscovery.script, arguments: [:], in: nil, contentWorld: .defaultClient) as? [String]
        #expect(updated?.last == "https://example.com/updates/feed")
    }

    @Test func aiPeekPanelStaysSeparateFromUnchangedPreview() throws {
        let container = CGSize(width: 900, height: 700)
        let link = CGRect(x: 20, y: 20, width: 20, height: 10)
        for y in [100.0, 480.0] {
            let preview = CGRect(x: 200, y: y, width: 280, height: 200)
            let panel = try #require(PeekLayout.aiPanelFrame(preview: preview, link: link, container: container))
            #expect(!panel.intersects(preview))
            #expect(panel.width == preview.width)
            #expect(CGRect(origin: .zero, size: container).contains(panel))
            #expect(preview.size == CGSize(width: 280, height: 200))
        }
        #expect(PeekLayout.aiPanelFrame(preview: CGRect(x: 20, y: 20, width: 280, height: 200), link: link, container: CGSize(width: 320, height: 240)) == nil)
    }

    @Test func printingIsAllowedByTheSandbox() throws {
        // These tests are hosted by Origami.app. Inspect its actual signature rather
        // than the compile-time checkout, which need not exist on Cloud test VMs.
        var runningCode: SecCode?
        try #require(SecCodeCopySelf([], &runningCode) == errSecSuccess)
        let host = try #require(runningCode)
        var staticCode: SecStaticCode?
        try #require(SecCodeCopyStaticCode(host, [], &staticCode) == errSecSuccess)
        let signedHost = try #require(staticCode)
        var information: CFDictionary?
        try #require(SecCodeCopySigningInformation(signedHost, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess)
        let signingInfo = try #require(information as? [String: Any])
        let entitlements = try #require(signingInfo[kSecCodeInfoEntitlementsDict as String] as? [String: Any])
        #expect(entitlements["com.apple.security.app-sandbox"] as? Bool == true)
        #expect(entitlements["com.apple.security.print"] as? Bool == true)
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
        let dismissDeadline = Date().addingTimeInterval(3)
        while store.peekPage != nil && Date() < dismissDeadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(store.peekPage == nil && store.peekSourceID == nil)
        #expect(store.session.tabs.count == count && store.selectedPage === page)
    }
}
