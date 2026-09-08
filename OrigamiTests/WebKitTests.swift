import Foundation
import Testing
import WebKit
@testable import Origami

@MainActor
struct WebKitTests {
    @Test(.timeLimit(.minutes(1)))
    func internalPageBridgeRejectsOrdinaryDocuments() async throws {
        let store = BrowserStore()
        let page = try #require(store.selectedPage)
        defer { page.dispose() }
        #expect(page.nativePage == .newtab)
        #expect(page.webView.url == nil)
        page.load(documentURL("<title>Ordinary Document</title>"))
        try await waitUntil("ordinary document") { page.webView.title == "Ordinary Document" && !page.isLoading }
        var rejected = false
        do {
            _ = try await page.webView.callAsyncJavaScript("return await window.webkit.messageHandlers.origami.postMessage({method:'settings.write',params:{layout:'vertical',search:'bing',restore:false}})", arguments: [:], in: nil, contentWorld: .page)
        } catch { rejected = true }
        #expect(rejected)
        #expect(store.session.searchEngine == .google)
        #expect(store.session.layout == .horizontal)
    }

    @Test
    func navigationInterruptionsDoNotReplaceThePageWithAnError() {
        let page = TabPage()
        defer { page.dispose() }
        for error in [NSError(domain: "WebKitErrorDomain", code: 102),
                      NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)] {
            page.webView(page.webView, didFailProvisionalNavigation: nil, withError: error)
            #expect(page.errorMessage == nil)
            page.webView(page.webView, didFail: nil, withError: error)
            #expect(page.errorMessage == nil)
        }
        for error in [NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost),
                      NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted),
                      NSError(domain: "WebKitErrorDomain", code: 101),
                      NSError(domain: "UnrelatedDomain", code: 102),
                      NSError(domain: "UnrelatedDomain", code: NSURLErrorCancelled)] {
            page.webView(page.webView, didFailProvisionalNavigation: nil, withError: error)
            #expect(page.errorMessage == error.localizedDescription)
            page.webView(page.webView, didCommit: nil)
            #expect(page.errorMessage == nil)
            page.webView(page.webView, didFail: nil, withError: error)
            #expect(page.errorMessage == error.localizedDescription)
            page.webView(page.webView, didFinish: nil)
            #expect(page.errorMessage == nil)
        }
    }

    @Test
    func desktopBrowserIdentityIsAvailableBeforeNavigation() async throws {
        let page = TabPage()
        defer { page.dispose() }
        let identity = try #require(try await page.webView.evaluateJavaScript("navigator.userAgent") as? String)
        #expect(identity.contains("Macintosh"))
        #expect(identity.contains("AppleWebKit/"))
        #expect(identity.contains("Version/"))
        #expect(identity.contains("Safari/"))
        #expect(!identity.contains("Chrome/"))
    }

    @Test(.timeLimit(.minutes(1)))
    func resizingHostUpdatesCSSViewport() async throws {
        let page = TabPage()
        defer { page.dispose() }
        let host = WebContentHost(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        host.attach(page.webView)
        page.load(documentURL("<title>Responsive fixture</title><script>window.resizeCount=0;addEventListener('resize',()=>window.resizeCount++)</script>"))
        try await waitUntil("responsive fixture") { page.webView.title == "Responsive fixture" && !page.isLoading }
        for size in [CGSize(width: 1440, height: 900), CGSize(width: 640, height: 480), CGSize(width: 1000, height: 700)] {
            host.setFrameSize(size)
            #expect(page.webView.frame.size == size)
            var matched = false
            for _ in 0..<50 {
                let result = try await page.webView.evaluateJavaScript("[innerWidth,innerHeight,matchMedia('(min-width: 900px)').matches,resizeCount]")
                if let values = result as? [NSNumber], values.count == 4,
                   values[0].doubleValue == size.width, values[1].doubleValue == size.height,
                   values[2].boolValue == (size.width >= 900), values[3].intValue > 0 {
                    matched = true
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(matched, "WebKit viewport, media query, and resize event must reflect the host size")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func pageStateSurvivesTwentyTabsAndLayouts() async throws {
        let store = BrowserStore()
        let first = try #require(store.selectedTab?.id)
        let firstPage = store.page(for: first)
        firstPage.load(documentURL("<html><head><title>Original</title></head><body><input id='draft'><div style='height:4000px'></div></body></html>"))
        try await waitUntil("initial HTML load") { firstPage.webView.title == "Original" && !firstPage.webView.isLoading }
        _ = try await firstPage.webView.evaluateJavaScript("window.marker = 42; document.querySelector('#draft').value = 'unsent draft'; window.scrollTo(0, 300);")
        for index in 1..<20 {
            let id = store.newTab()
            let page = store.page(for: id)
            page.load(documentURL("<title>Tab \(index)</title><p>Independent page \(index)</p>"))
            try await waitUntil("HTML load for tab \(index)") { page.webView.title == "Tab \(index)" && !page.webView.isLoading }
        }
        store.setLayout(.vertical)
        store.select(first)
        #expect(store.selectedPage === firstPage)
        #expect(try await firstPage.webView.evaluateJavaScript("window.marker") as? Int == 42)
        #expect(try await firstPage.webView.evaluateJavaScript("document.querySelector('#draft').value") as? String == "unsent draft")
        store.setLayout(.horizontal)
        firstPage.load(documentURL("<title>Second Document</title><p>Navigation destination</p>"))
        try await waitUntil("second document") { firstPage.webView.title == "Second Document" && !firstPage.isLoading }
        #expect(firstPage.canGoBack)
        firstPage.goBack()
        try await waitUntil("back navigation") { firstPage.webView.title == "Original" && firstPage.canGoForward }
        firstPage.goForward()
        try await waitUntil("forward navigation") { firstPage.webView.title == "Second Document" && !firstPage.isLoading }
        _ = try await firstPage.webView.evaluateJavaScript("document.title = 'Changed'")
        firstPage.reload()
        try await waitUntil("reload") { firstPage.webView.title == "Second Document" && !firstPage.isLoading }
        #expect(store.session.tabs.count == 20)
        let secondPage = store.page(for: store.session.tabs[1].id)
        #expect(try await secondPage.webView.evaluateJavaScript("typeof window.marker") as? String == "undefined")
        for id in store.session.tabs.map(\.id) { store.close(id) }
    }
    @Test(.timeLimit(.minutes(1)))
    func failureCallbackKeepsRequestedAddress() async throws {
        let store = BrowserStore()
        let page = try #require(store.selectedPage)
        page.load(documentURL("<title>Previous Page</title>"))
        try await waitUntil("previous page") { page.webView.title == "Previous Page" && !page.isLoading }
        let destination = "http://127.0.0.1:1/unavailable"
        store.navigate(destination)
        page.webView.stopLoading()
        // Exercise error handling without depending on the operating system's network timeout.
        page.webView(page.webView, didFailProvisionalNavigation: nil,
                     withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost))
        #expect(page.errorMessage != nil)
        #expect(store.selectedTab?.url?.absoluteString == destination)
        page.reload()
        #expect(page.errorMessage == nil)
        #expect(page.currentURL?.absoluteString == destination)
        page.dispose()
    }
    @Test(.timeLimit(.minutes(1)))
    func manualSleepAllowsUntouchedControlsAndEmbedsButAutomaticSleepStaysConservative() async throws {
        let store = BrowserStore()
        let id = try #require(store.selectedTab?.id), page = store.page(for: id)
        defer { store.pages.values.forEach { $0.dispose() }; page.dispose() }
        page.load(documentURL("<title>Idle form</title><input type=password><input type=file><select><option>One</option><option>Two</option></select><iframe srcdoc='<p>Embed</p>'></iframe>"))
        try await waitUntil("idle form") { page.webView.title == "Idle form" && !page.isLoading }
        #expect(try await page.webView.evaluateJavaScript("window.__origamiActivity.canManuallySleep") as? Bool == true)
        #expect(try await page.webView.evaluateJavaScript("window.__origamiActivity.safeToSleep") as? Bool == false)
        _ = store.newTab()
        page.activity.lastActive = .distantPast
        await store.sleep(id, automatic: true)
        #expect(store.loadedPage(for: id) === page)
        await store.sleep(id)
        #expect(store.session.tabs.first { $0.id == id }?.isSleeping == true)
        #expect(store.loadedPage(for: id) == nil)
        let native = store.newTab()
        _ = store.page(for: native)
        await store.sleep(native)
        #expect(store.session.tabs.first { $0.id == native }?.isSleeping == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func sleepingPreservesDetectedDraftsAndWakesWithANewContext() async throws {
        let store = BrowserStore()
        let first = try #require(store.selectedTab?.id), page = store.page(for: first)
        defer { store.pages.values.forEach { $0.dispose() }; page.dispose() }
        page.load(documentURL("<title>Draft fixture</title><input id='draft'>"))
        try await waitUntil("sleep fixture") { page.webView.title == "Draft fixture" && !page.isLoading }
        _ = store.newTab()
        _ = try await page.webView.evaluateJavaScript("document.querySelector('#draft').value='Unsaved'")
        await store.sleep(first)
        #expect(store.loadedPage(for: first) === page)
        _ = try await page.webView.evaluateJavaScript("document.querySelector('#draft').value=''")
        store.togglePin(first)
        await store.sleep(first)
        #expect(store.loadedPage(for: first) === page)
        store.togglePin(first)
        await store.sleep(first)
        #expect(store.loadedPage(for: first) == nil)
        #expect(store.session.tabs.first(where: { $0.id == first })?.isSleeping == true)
        store.select(first)
        #expect(store.selectedTab?.isSleeping != true)
        #expect(store.selectedPage !== page)
    }
    @Test(.timeLimit(.minutes(1)))
    func nativeDestinationsPreserveLiveWebsiteAndNavigation() async throws {
        let store = BrowserStore()
        let page = try #require(store.selectedPage)
        defer { store.pages.values.forEach { $0.dispose() } }
        page.load(documentURL("<title>Retained Website</title><input id='draft'>"))
        try await waitUntil("retained website") { page.webView.title == "Retained Website" && !page.isLoading }
        _ = try await page.webView.evaluateJavaScript("window.marker=37;document.querySelector('#draft').value='Keep this'")
        page.load(InternalPage.history.url)
        #expect(page.nativePage == .history)
        #expect(page.currentURL == InternalPage.history.url)
        page.load(InternalPage.settings.url)
        page.goBack()
        #expect(page.nativePage == .history)
        page.goBack()
        #expect(page.nativePage == nil)
        #expect(try await page.webView.evaluateJavaScript("window.marker") as? Int == 37)
        #expect(try await page.webView.evaluateJavaScript("document.querySelector('#draft').value") as? String == "Keep this")
        page.goForward()
        #expect(page.nativePage == .history)
        page.reload()
        #expect(page.nativeRevision == 1)
        #expect(page.nativePage == .history)
        #expect(page.webView.title == "Retained Website")
    }

    @Test(.timeLimit(.minutes(1)))
    func sameDocumentNavigationUsesBrowserHistory() async throws {
        let page = TabPage()
        defer { page.dispose() }
        page.load(documentURL("<title>Hash navigation</title><div id='section'>Section</div>"))
        try await waitUntil("hash fixture") { page.webView.title == "Hash navigation" && !page.isLoading }
        let initialURL = page.currentURL
        _ = try await page.webView.evaluateJavaScript("location.hash='section'")
        // WebKit percent-encodes the fragment separator in data: fixture URLs.
        try await waitUntil("hash navigation") { page.destinationHistory.entries.count == 2 && page.currentURL != initialURL }
        let anchoredURL = page.currentURL
        page.load(InternalPage.settings.url)
        page.goBack()
        try await waitUntil("return to hash") { page.currentURL == anchoredURL }
        page.goBack()
        try await waitUntil("hash back") { page.currentURL == initialURL && page.nativePage == nil }
        #expect(page.canGoForward)
    }

    @Test(.timeLimit(.minutes(1)))
    func pausedMutedElementsAreNotPlayingMedia() async throws {
        let page = TabPage()
        defer { page.dispose() }
        page.load(documentURL("<title>Idle media</title><video muted></video>"))
        try await waitUntil("idle media fixture") { page.webView.title == "Idle media" && !page.isLoading }
        _ = try await page.webView.evaluateJavaScript("document.querySelector('video').muted=true")
        let state = await MediaStateService().sample(page.webView)
        #expect(!state.isRelevant)
        #expect(!state.isPlayingMedia)
        _ = try await page.webView.evaluateJavaScript("document.querySelector('video').remove()")
        let empty = await MediaStateService().sample(page.webView)
        #expect(empty.isMuted == nil)
        #expect(!empty.isPlayingMedia)
    }

    private func documentURL(_ html: String) -> URL {
        URL(string: "data:text/html;base64," + Data(html.utf8).base64EncodedString())!
    }
    private func waitUntil(_ label: String, _ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("WebKit timed out: \(label)")
        throw CocoaError(.executableRuntimeMismatch)
    }
}
