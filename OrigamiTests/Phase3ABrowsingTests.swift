import Foundation
import Testing
import WebKit
import GRDB
@testable import Origami

@MainActor struct Phase3ABrowsingTests {
    @Test func fileLinksDoNotOpenPeekAndReferencesUseNativeTab() throws {
        let store = BrowserStore()
        defer { store.dismissPeek(); store.pages.values.forEach { $0.dispose() } }
        for address in ["https://example.com/image.JPG", "https://example.com/file.pdf?download=1", "https://example.com/app.dmg", "https://www.google.com/imgres?imgurl=https://example.com/a"] {
            store.openPeek(try #require(URL(string: address)))
            #expect(store.peekPage == nil)
        }
        store.openInternal(.references)
        #expect(store.selectedTab?.url == InternalPage.references.url)
        #expect(InternalRoute.page(for: InternalPage.references.url) == .references)
    }
    @Test func peekPromotionRetainsWebViewAndDoesNotPersistUntilPromoted() throws {
        let store = BrowserStore()
        let count = store.session.tabs.count
        store.openPeek(URL(string: "https://example.invalid/article")!)
        let peek = try #require(store.peekPage)
        #expect(store.session.tabs.count == count)
        #expect(peek.isPassivePreview)
        #expect(!store.pages.values.contains { $0 === peek })
        store.promotePeek()
        #expect(!peek.isPassivePreview)
        #expect(store.peekPage == nil)
        #expect(store.pages[peek.tabID] === peek)
        #expect(store.session.tabs.count == count + 1)
        #expect(store.session.selectedTabID == peek.tabID)
        store.openPeek(URL(string: "https://example.invalid/other")!)
        store.dismissPeek()
        #expect(store.peekPage == nil)
        #expect(store.session.tabs.count == count + 1)
        store.pages.values.forEach { $0.dispose() }
    }
    @Test func privatePeekAndSplitShareOnlyTheEphemeralStore() throws {
        let app = BrowserApplicationContext(isolated: true)
        let window = try #require(app.newPrivateWindow())
        let original = try #require(window.selectedPage)
        window.openPeek(URL(string: "https://example.invalid/private")!)
        let peek = try #require(window.peekPage)
        #expect(!peek.webView.configuration.websiteDataStore.isPersistent)
        #expect(peek.webView.configuration.websiteDataStore === original.webView.configuration.websiteDataStore)
        #expect(window.persistence == nil)
        window.promotePeek()
        window.splitWith(original.tabID)
        #expect(window.session.split != nil)
        app.close(window.session.windowID)
        #expect(!app.stores.values.contains { $0.isPrivate })
    }

    @Test func draggingTabsIntoPageUsesDropSideAndRetainsPages() throws {
        let store = BrowserStore()
        defer { store.pages.values.forEach { $0.dispose() } }
        let current = try #require(store.session.selectedTabID)
        let dragged = store.newTab()
        store.select(current)
        let originalPage = store.page(for: current)
        let draggedPage = store.page(for: dragged)
        store.pageDropFrames = [current: CGRect(x: 200, y: 100, width: 800, height: 600)]
        #expect(store.pageSplitTarget(for: current, at: CGPoint(x: 300, y: 200)) == nil)
        #expect(store.pageSplitTarget(for: dragged, at: CGPoint(x: 100, y: 200)) == nil)
        #expect(store.pageSplitTarget(for: UUID(), at: CGPoint(x: 300, y: 200)) == nil)
        let left = try #require(store.pageSplitTarget(for: dragged, at: CGPoint(x: 300, y: 200)))
        store.dropTabIntoPage(dragged, target: left)
        #expect(store.session.activeSplit == BrowserSplit(left: dragged, right: current))
        let right = try #require(store.pageSplitTarget(for: dragged, at: CGPoint(x: 800, y: 200)))
        store.dropTabIntoPage(dragged, target: right)
        #expect(store.session.activeSplit == BrowserSplit(left: current, right: dragged))
        #expect(store.pages[current] === originalPage)
        #expect(store.pages[dragged] === draggedPage)
        #expect(store.session.tabs.count == 2)
        store.dropTabIntoPage(current, target: PageSplitDropTarget(pageID: current, onLeft: true))
        #expect(store.session.activeSplit == BrowserSplit(left: current, right: dragged))
        store.detachSplitTab(dragged)
        #expect(store.session.split == nil)
        #expect(store.session.visibleTabIDs.count == 2)
    }

    @Test func splitPersistsSwapsAndCollapsesWhenTabCloses() throws {
        let db = try DatabaseManager()
        _ = try ProfileRepository(db).ensureDefault()
        let store = BrowserStore()
        let left = try #require(store.session.selectedTabID)
        let right = store.newTab()
        store.select(left); store.splitWith(right)
        #expect(store.session.split == BrowserSplit(left: left, right: right))
        let leftView = store.pages[left]?.webView
        store.swapSplit()
        #expect(store.pages[left]?.webView === leftView)
        let repository = SessionRepository(db)
        try repository.save(store.session)
        let restored = try #require(try repository.load(profileID: store.session.profileID))
        #expect(restored.split == BrowserSplit(left: right, right: left))
        store.close(right)
        #expect(store.session.split == nil)
        store.pages.values.forEach { $0.dispose() }
    }
    @Test func rssAtomAndOPMLParseWithoutExecutingMarkup() throws {
        let base = URL(string: "https://example.com/feed")!
        let rss = Data("<rss><channel><title>Example</title><item><guid>1</guid><title>Article</title><link>/article</link><pubDate>Mon, 01 Sep 2025 10:00:00 +0000</pubDate></item></channel></rss>".utf8)
        let result = try FeedParser(base: base).parse(rss)
        #expect(result.title == "Example")
        #expect(result.items.first?.url == "https://example.com/article")
        let atom = Data("<feed xmlns='http://www.w3.org/2005/Atom'><title>Atom</title><entry><id>2</id><title>Entry</title><link href='/second'/><updated>2025-09-01T10:00:00Z</updated></entry></feed>".utf8)
        #expect(try FeedParser(base: base).parse(atom).items.first?.url == "https://example.com/second")
        let opml = Data("<opml><body><outline text='Work'><outline xmlUrl='https://example.com/feed'/><outline xmlUrl='javascript:bad'/></outline></body></opml>".utf8)
        let entries = try OPMLParser().parse(opml)
        #expect(entries.count == 1)
        #expect(entries.first?.1 == "Work")
    }
    @Test func feedReadStateIsProfileScopedAndOPMLRoundTrips() throws {
        let db = try DatabaseManager()
        let profiles = ProfileRepository(db)
        let personal = try profiles.ensureDefault()
        let work = try profiles.create(name: "Work")
        let feeds = FeedService(database: db)
        try db.queue.write { db in
            try db.execute(sql: "INSERT INTO feeds VALUES('f',?,'https://example.com/feed','A & B','Work')", arguments: [personal.id.uuidString])
            try db.execute(sql: "INSERT INTO feed_articles VALUES('a','f','Article','https://example.com/a',100,0)")
        }
        #expect(try feeds.feeds(profile: work.id).isEmpty)
        let article = try #require(try feeds.articles(profile: personal.id).first)
        try feeds.mark(article, read: true)
        #expect(try feeds.articles(profile: personal.id).first?.read == true)
        let imported = try OPMLParser().parse(feeds.exportOPML(profile: personal.id))
        #expect(imported.first?.0.absoluteString == "https://example.com/feed")
        #expect(imported.first?.1 == "Work")
    }
    @Test func jsonPathsAndGlobalDefaults() throws {
        let object = try JSONSerialization.jsonObject(with: Data(#"{"a'b":[true,null,3]}"#.utf8))
        let tree = JSONTreeNode.make(object)
        #expect(tree.children.first?.id == "$['a\\'b']")
        #expect(tree.children.first?.children.last?.id == "$['a\\'b'][2]")
        #expect(tree.children.first?.children.last?.value == "3")
        let preferences = BrowserPreferences()
        #expect(!preferences.globalSearchEnabled && !preferences.quickHideEnabled)
        #expect(preferences.searchHotKey == BrowserHotKey(key: 49, modifiers: 6144, label: "⌃⌥Space"))
        preferences.searchHotKey = BrowserHotKey(key: 1, modifiers: 256, label: "⌘S")
        #expect(preferences.searchHotKey.key == 1)
    }
    @Test func globalShortcutCanRegisterWithoutAccessibilityPermission() throws {
        let app = BrowserApplicationContext(isolated: true)
        let store = app.resolve(nil)
        app.activeID = store.session.windowID
        store.preferences.globalSearchEnabled = true
        store.preferences.searchHotKey = BrowserHotKey(key: 80, modifiers: 6912, label: "⌃⌥⇧⌘F19")
        let controls = GlobalBrowserControls(application: app)
        defer { controls.stop(); app.close(store.session.windowID) }
        #expect(controls.error == nil)
    }

    @Test(.timeLimit(.minutes(1))) func readerRefreshFindsLateDocumentationAndRejectsLinkLists() async throws {
        let page = TabPage()
        defer { page.dispose() }
        page.webView.loadHTMLString("<html><head><title>Documentation</title></head><body><main id='content'></main></body></html>", baseURL: URL(string: "https://example.invalid/docs"))
        let deadline = Date().addingTimeInterval(15)
        while page.webView.isLoading || page.webView.title != "Documentation" {
            guard Date() < deadline else { throw RepositoryError.invalidInput }
            try await Task.sleep(for: .milliseconds(50))
        }
        page.documentTask?.cancel()
        await page.discoverDocuments()
        #expect(page.article == nil)
        let paragraph = "Choose the technologies for your application and create its interface using native components. Each platform defines the look and behavior of its controls. Build your interface with standard views and manage the data that supports them. These approaches help your application provide a consistent experience."
        // Content arrives after the initial discovery, as on client-rendered documentation sites.
        let html = "<h1>Documentation</h1><p>" + paragraph + "</p><p>" + paragraph + "</p>"
        _ = try await page.webView.callAsyncJavaScript("document.getElementById('content').innerHTML = html", arguments: ["html": html], in: nil, contentWorld: .defaultClient)
        await page.discoverDocuments()
        #expect(try #require(page.article).markdown.contains("native components"))
        page.article = nil
        _ = try await page.webView.callAsyncJavaScript("document.getElementById('content').innerHTML = html", arguments: ["html": "<h1>Links</h1><p><a href='/one'>" + paragraph + "</a></p><p><a href='/two'>" + paragraph + "</a></p>"], in: nil, contentWorld: .defaultClient)
        await page.discoverDocuments()
        #expect(page.article == nil)
    }

    @Test(.timeLimit(.minutes(1))) func readerPreservesSafeArticleMediaInOrder() async throws {
        let page = TabPage()
        defer { page.dispose() }
        let prose = String(repeating: "This article explains native interfaces and accessible interactions with practical examples. ", count: 5)
        let html = "<html><head><title>Media article</title></head><body><article><h1>Media article</h1><p>Before image. " + prose + "</p><figure><img data-src='/photo.png' alt='Article photograph'></figure><p>Between media. " + prose + "</p><video preload='none' src='/clip.mp4' title='Demonstration'></video><p>After video. " + prose + "</p><iframe data-src='https://video.example.invalid/embed/123' title='Embedded demonstration'></iframe><img data-src='javascript:alert(1)'><img data-src='https://user:pass@example.invalid/private.png'></article></body></html>"
        page.webView.loadHTMLString(html, baseURL: URL(string: "https://example.invalid/article"))
        let deadline = Date().addingTimeInterval(15)
        while page.webView.isLoading || page.webView.title != "Media article" {
            guard Date() < deadline else { throw RepositoryError.invalidInput }
            try await Task.sleep(for: .milliseconds(50))
        }
        await page.discoverDocuments()
        let article = try #require(page.article)
        #expect(article.media.count == 3)
        #expect(article.media[2].kind == "embed")
        #expect(article.media[0].url?.absoluteString == "https://example.invalid/photo.png")
        #expect(article.media[1].kind == "video")
        let blocks = article.markdown.components(separatedBy: "\n\n")
        let image = try #require(blocks.firstIndex { article.mediaBlock($0)?.kind == "image" })
        let video = try #require(blocks.firstIndex { article.mediaBlock($0)?.kind == "video" })
        #expect(image < video)
        #expect(article.exportMarkdown.contains("![Article photograph](https://example.invalid/photo.png)"))
        #expect(!article.exportMarkdown.contains("origami-media:"))
        for unsafe in ["file:///tmp/image.png", "javascript:alert(1)", "https://user:pass@example.invalid/image"] {
            #expect(ReaderMedia.safeURL(unsafe) == nil)
        }
    }

    @Test(.timeLimit(.minutes(1))) func readerExtractsArticleInWebKit() async throws {
        let page = TabPage()
        defer { page.dispose() }
        let paragraph = "Origami is a native browser with careful local article extraction. This paragraph explains how the application preserves the user's browsing context while presenting readable content. "
        let html = "<html><head><title>A Readable Article</title><meta name='author' content='Test Author'></head><body><nav>Unrelated navigation</nav><article><h1>A Readable Article</h1>" + (0..<12).map { "<p>Section \($0). \(paragraph)</p>" }.joined() + "</article></body></html>"
        page.webView.loadHTMLString(html, baseURL: URL(string: "https://example.com/article"))
        let deadline = Date().addingTimeInterval(15)
        while page.webView.isLoading || page.webView.title != "A Readable Article" {
            guard Date() < deadline else { throw RepositoryError.invalidInput }
            try await Task.sleep(for: .milliseconds(50))
        }
        await page.discoverDocuments()
        let article = try #require(page.article)
        #expect(article.title == "A Readable Article")
        #expect(article.author == "Test Author")
        #expect(!article.markdown.contains("Unrelated navigation"))
        #expect(article.minutes > 0)
        #expect(article.markdown.contains("\n\n"))
    }
}
