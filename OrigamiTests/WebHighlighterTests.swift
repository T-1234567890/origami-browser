import Testing
import WebKit
import GRDB
@testable import Origami

@MainActor struct WebHighlighterTests {
    private let url = URL(string: "https://example.invalid/article")!
    private func anchor(_ text: String = "A selected quotation with enough words.") -> HighlightAnchor {
        HighlightAnchor(text: text, prefix: "Before ", suffix: " After", startPath: [0,0], endPath: [0,0], startOffset: 7, endOffset: 45, position: 7)
    }
    @Test func persistenceReopenUpdateRemoveAndProfileIsolation() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "highlights.sqlite")
        let database = try DatabaseManager(fileURL: path)
        let profiles = ProfileRepository(database); _ = try profiles.ensureDefault()
        let other = try profiles.create(name: "Fixture", color: .mint)
        let store = HighlightStore(database: database)
        var record = HighlightRecord(url: url.absoluteString, pageTitle: "Synthetic page", anchor: anchor(), style: .yellow)
        try store.save(record, profile: BrowserProfile.defaultID)
        let reopened = HighlightStore(database: try DatabaseManager(fileURL: path))
        #expect(try reopened.records(url: url, profile: BrowserProfile.defaultID) == [record])
        #expect(try reopened.records(url: url, profile: other.id).isEmpty)
        record.style = .lavender; try reopened.save(record, profile: BrowserProfile.defaultID)
        #expect(try store.records(url: url, profile: BrowserProfile.defaultID).first?.style == .lavender)
        try store.remove(record.id, url: url.absoluteString, profile: other.id)
        #expect(try store.records(url: url, profile: BrowserProfile.defaultID).count == 1)
        try store.remove(record.id, url: url.absoluteString, profile: BrowserProfile.defaultID)
        #expect(try reopened.records(url: url, profile: BrowserProfile.defaultID).isEmpty)
        try store.save(record, profile: other.id); try profiles.delete(other.id)
        #expect(try store.records(url: url, profile: other.id).isEmpty)
    }
    @Test func privateHighlightsDoNotEnterNormalStorage() throws {
        let normal = try BrowserServices(database: DatabaseManager(), preferences: BrowserPreferences())
        let profile = try #require(normal.profiles.list().first)
        let privateServices = try BrowserServices(database: DatabaseManager(), preferences: BrowserPreferences(), privateProfile: profile)
        let record = HighlightRecord(url: url.absoluteString, pageTitle: "Private fixture", anchor: anchor(), style: .mint)
        try privateServices.highlighter.store.save(record, profile: profile.id)
        #expect(try privateServices.highlighter.store.records(url: url, profile: profile.id).count == 1)
        #expect(try normal.highlighter.store.records(url: url, profile: profile.id).isEmpty)
        let fresh = try BrowserServices(database: DatabaseManager(), preferences: BrowserPreferences(), privateProfile: profile)
        #expect(try fresh.highlighter.store.records(url: url, profile: profile.id).isEmpty)
    }
    @Test func closingPrivateWindowClearsRetainedHighlightStore() throws {
        let app = BrowserApplicationContext(isolated: true)
        defer { for id in Array(app.stores.keys) { app.close(id) } }
        let window = try #require(app.newPrivateWindow())
        let store = try #require(window.services?.highlighter.store)
        try store.save(HighlightRecord(url: url.absoluteString, pageTitle: "Fixture", anchor: anchor(), style: .yellow), profile: window.session.profileID)
        app.close(window.session.windowID)
        #expect(try store.records(url: url, profile: window.session.profileID).isEmpty)
    }
    @Test func nativeActionsSaveChangeStyleRemoveAndRejectPageMessages() async throws {
        let db = try DatabaseManager(); _ = try ProfileRepository(db).ensureDefault()
        let manager = HighlightManager(database: db, preferences: BrowserPreferences()); manager.enabled = true
        let controller = WebHighlighterController()
        let h = try await Fixture(html: "<p id='target'>A selected quotation with enough words.</p>", controller: controller, manager: manager)
        defer { controller.dispose(); h.dispose() }
        func selectForNative() async throws {
            _ = try await h.select("#target")
            _ = try await h.web.callAsyncJavaScript("""
              const value=window.__origamiHighlighter.selection();
              window.webkit.messageHandlers.origamiHighlight.postMessage({kind:'selection',documentID:doc,url:location.href,...value});
            """, arguments: ["doc": h.bridge.documentID], in: nil, contentWorld: HighlightScript.world)
            for _ in 0..<30 { if controller.selection != nil { break }; await Task.yield() }
            #expect(controller.selection != nil)
        }
        try await selectForNative()
        await controller.apply(style: .mint)
        #expect(try manager.store.records(url: url, profile: BrowserProfile.defaultID).first?.style == .mint)
        // Let the controller's updated ranges reach WebKit before selecting the same text again.
        for _ in 0..<50 {
            if try await h.js("return [...CSS.highlights.values()].reduce((n,h)=>n+h.size,0)") as? Int == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await selectForNative()
        #expect(controller.selection?.existingID != nil)
        await controller.apply(style: .lavender)
        #expect(try manager.store.records(url: url, profile: BrowserProfile.defaultID).count == 1)
        #expect(try manager.store.records(url: url, profile: BrowserProfile.defaultID).first?.style == .lavender)
        try await Task.sleep(for: .milliseconds(50))
        try await selectForNative()
        await controller.apply(style: nil, remove: true)
        #expect(try manager.store.records(url: url, profile: BrowserProfile.defaultID).isEmpty)
    }
    @Test func bottomPanelToolsAutomaticallyHighlightEraseAndRemainVisibleWhenOff() async throws {
        let db = try DatabaseManager(); _ = try ProfileRepository(db).ensureDefault()
        let manager = HighlightManager(database: db, preferences: BrowserPreferences())
        manager.enabled = true; manager.style = .mint
        let controller = WebHighlighterController()
        let h = try await Fixture(html: "<p id='target'>A selected quotation with enough words.</p>", controller: controller, manager: manager)
        defer { controller.dispose(); h.dispose() }
        func sendSelection(commit: Bool) async throws {
            _ = try await h.select("#target")
            _ = try await h.web.callAsyncJavaScript("""
              const value=window.__origamiHighlighter.selection();
              window.webkit.messageHandlers.origamiHighlight.postMessage({kind:'selection',commit,documentID:doc,url:location.href,...value});
            """, arguments: ["doc": h.bridge.documentID, "commit": commit], in: nil, contentWorld: HighlightScript.world)
            try await Task.sleep(for: .milliseconds(100))
        }
        // Mutation/position updates must never save on their own.
        try await sendSelection(commit: false)
        #expect(try manager.store.records(url: url, profile: BrowserProfile.defaultID).isEmpty)
        try await sendSelection(commit: true)
        #expect(try manager.store.records(url: url, profile: BrowserProfile.defaultID).first?.style == .mint)
        manager.tool = .eraser; controller.refresh()
        try await Task.sleep(for: .milliseconds(100))
        try await sendSelection(commit: true)
        #expect(try manager.store.records(url: url, profile: BrowserProfile.defaultID).isEmpty)
        // An in-flight selection cannot commit after its tool is switched off.
        manager.tool = .off
        try await sendSelection(commit: true)
        #expect(manager.enabled)
        #expect(try manager.store.records(url: url, profile: BrowserProfile.defaultID).isEmpty)
        manager.tool = .highlight; manager.enabled = false
        try await sendSelection(commit: true)
        #expect(try manager.store.records(url: url, profile: BrowserProfile.defaultID).isEmpty)
    }
    @Test func nativeControllerReattachesAfterHistoryReset() async throws {
        let db = try DatabaseManager(); _ = try ProfileRepository(db).ensureDefault()
        let manager = HighlightManager(database: db, preferences: BrowserPreferences()); manager.enabled = true
        let controller = WebHighlighterController()
        let h = try await Fixture(html: "<p id='target'>A selected quotation with enough words.</p>", controller: controller, manager: manager)
        defer { controller.dispose(); h.dispose() }
        let value = try await h.capture("#target")
        let data = try JSONSerialization.data(withJSONObject: value)
        let anchor = try JSONDecoder().decode(HighlightAnchor.self, from: data)
        try manager.store.save(HighlightRecord(url: url.absoluteString, pageTitle: "Fixture", anchor: anchor, style: .yellow), profile: BrowserProfile.defaultID)
        controller.reset(); controller.refresh()
        for _ in 0..<50 {
            if try await h.js("return [...CSS.highlights.values()].reduce((n,h)=>n+h.size,0)") as? Int == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try await h.js("return [...CSS.highlights.values()].reduce((n,h)=>n+h.size,0)") as? Int == 1)
        for enabled in [false, true] {
            manager.enabled = enabled; controller.refresh()
            let expected = enabled ? 1 : 0
            for _ in 0..<50 {
                if try await h.js("return [...CSS.highlights.values()].reduce((n,h)=>n+h.size,0)") as? Int == expected { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(try await h.js("return [...CSS.highlights.values()].reduce((n,h)=>n+h.size,0)") as? Int == expected)
            #expect(try manager.store.records(url: url, profile: BrowserProfile.defaultID).count == 1)
        }
    }
    @Test func inputBoundsURLsAndPreferences() throws {
        for text in ["file:///tmp/fixture", "javascript:alert(1)", "https://user:pass@example.invalid/"] {
            #expect(HighlightStore.pageKey(URL(string: text)!) == nil)
        }
        #expect(HighlightStore.pageKey(URL(string: "https://example.invalid/?page=2#/article")!) == "https://example.invalid/?page=2#/article")
        #expect(!anchor(String(repeating: "x", count: 8001)).valid)
        let name = "Origami.HighlighterFixture." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
        let prefs = BrowserPreferences(defaults: defaults)
        #expect(!prefs.highlighterEnabled)
        prefs.highlighterEnabled = true; prefs.highlightStyle = .mint
        #expect(BrowserPreferences(defaults: defaults).highlighterEnabled)
        #expect(BrowserPreferences(defaults: defaults).highlightStyle == .mint)
    }

    @Test func DOMAndQuoteRestorationAfterMarkupChanges() async throws {
        let h = try await Fixture(html: "<p id='text'>Before the quote. <span>A selected quotation with enough words.</span> After the quote.</p>")
        defer { h.dispose() }
        let captured = try await h.capture("#text span")
        #expect(try await h.resolve(captured) == "A selected quotation with enough words.")
        _ = try await h.js("document.querySelector('#text').innerHTML='Before the quote. <strong>A selected quotation with enough words.</strong> After the quote.'")
        #expect(try await h.resolve(captured) == "A selected quotation with enough words.")
    }
    @Test func duplicateQuotesRequireDistinctContext() async throws {
        let quote = "A repeated quotation with enough words."
        let h = try await Fixture(html: "<p>First context <span>\(quote)</span> first ending.</p><p>Second context <span id='target'>\(quote)</span> second ending.</p>")
        defer { h.dispose() }
        let captured = try await h.capture("#target")
        _ = try await h.js("document.body.insertAdjacentHTML('afterbegin','<div>New content</div>')")
        #expect(try await h.resolve(captured) == quote)
        var ambiguous = captured; ambiguous["prefix"] = ""; ambiguous["suffix"] = ""
        #expect(try await h.resolve(ambiguous) == nil)
    }
    @Test func fuzzyRequiresUniqueContextAndSmallEdit() async throws {
        let original = "This carefully selected quotation contains many useful words for testing."
        let h = try await Fixture(html: "<p>Unique surrounding context before <span id='target'>\(original)</span> unique surrounding context afterward.</p>")
        defer { h.dispose() }
        let captured = try await h.capture("#target")
        _ = try await h.js("document.querySelector('#target').textContent='This carefully selected quotation contains many useful word for testing.'")
        #expect(try await h.resolve(captured) == "This carefully selected quotation contains many useful word for testing.")
        _ = try await h.js("document.querySelector('#target').textContent='Something entirely unrelated must never be highlighted.'")
        #expect(try await h.resolve(captured) == nil)
    }
    @Test func editableLinksHiddenAndCrossControlSelectionsAreRejected() async throws {
        let h = try await Fixture(html: "<p contenteditable><span id='edit'>Editable words</span></p><a id='link' href='/'>Linked words</a><div hidden id='hidden'>Hidden words</div><p id='cross'>Before <input type='password' value='fixture'> after</p>")
        defer { h.dispose() }
        for selector in ["#edit", "#link", "#hidden", "#cross"] {
            let result = try await h.select(selector)
            #expect(result == nil)
        }
    }
    @Test func restoreDoesNotWrapDOMAndRepeatedRestoreDoesNotDuplicate() async throws {
        let h = try await Fixture(html: "<p id='target'>A selected quotation with enough words.</p>")
        defer { h.dispose() }
        let captured = try await h.capture("#target")
        let before = try await h.js("return document.body.innerHTML") as? String
        try await h.configure(anchor: captured)
        try await h.configure(anchor: captured)
        #expect(try await h.js("return [...CSS.highlights.values()].reduce((n,h)=>n+h.size,0)") as? Int == 1)
        #expect(try await h.js("return document.body.innerHTML") as? String == before)
        try await h.configure(anchor: captured, enabled: false)
        #expect(try await h.select("#target") == nil)
        #expect(try await h.js("return [...CSS.highlights.values()].reduce((n,h)=>n+h.size,0)") as? Int == 1)
    }
    @Test func dynamicContentRestoresAndSPARouteClearsOldHighlights() async throws {
        let h = try await Fixture(html: "<p id='target'>A selected quotation with enough words.</p>")
        defer { h.dispose() }
        let captured = try await h.capture("#target")
        _ = try await h.js("document.querySelector('#target').remove()")
        try await h.configure(anchor: captured)
        #expect(try await h.js("return [...CSS.highlights.values()].reduce((n,h)=>n+h.size,0)") as? Int == 0)
        _ = try await h.js("document.body.innerHTML='<p id=target>A selected quotation with enough words.</p>'")
        for _ in 0..<60 {
            if try await h.js("return [...CSS.highlights.values()].reduce((n,h)=>n+h.size,0)") as? Int == 1 { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(try await h.js("return [...CSS.highlights.values()].reduce((n,h)=>n+h.size,0)") as? Int == 1)
        _ = try await h.js("history.pushState({},'', '/different')")
        for _ in 0..<40 {
            if h.bridge.url.hasSuffix("/different") { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(h.bridge.url.hasSuffix("/different"))
        #expect(try await h.js("return [...CSS.highlights.values()].reduce((n,h)=>n+h.size,0)") as? Int == 0)
    }
    @Test func unrelatedMutationPreservesPendingSelection() async throws {
        let h = try await Fixture(html: "<p id='target'>A selected quotation with enough words.</p><p id='other'>Other content</p>")
        defer { h.dispose() }
        let anchor = try await h.capture("#target")
        try await h.configure(anchor: anchor)
        let value = try #require(try await h.select("#target"))
        let token = try #require(value["token"] as? Int)
        _ = try await h.js("document.querySelector('#other').textContent='Updated content'")
        try await Task.sleep(for: .milliseconds(1300))
        let raw = try await h.web.callAsyncJavaScript("return window.__origamiHighlighter.snapshot(token)", arguments: ["token": token], in: nil, contentWorld: HighlightScript.world)
        let pending = try #require(raw as? [String: Any])
        #expect(pending["token"] as? Int == token)
    }
    @Test func staleSelectionCannotBeSavedAfterPageChanges() async throws {
        let h = try await Fixture(html: "<p id='target'>A selected quotation with enough words.</p>")
        defer { h.dispose() }
        let value = try #require(try await h.select("#target"))
        let token = try #require(value["token"] as? Int)
        _ = try await h.js("document.querySelector('#target').textContent='Changed text'")
        let result = try await h.web.callAsyncJavaScript("return window.__origamiHighlighter.snapshot(token)", arguments: ["token": token], in: nil, contentWorld: HighlightScript.world)
        #expect(result == nil || result is NSNull)
    }
    @Test func pageWorldCannotAccessNativeHighlightBridge() async throws {
        let h = try await Fixture(html: "<p>Public page</p>")
        defer { h.dispose() }
        let value = try await h.web.callAsyncJavaScript("return !!window.webkit?.messageHandlers?.origamiHighlight", arguments: [:], in: nil, contentWorld: .page)
        #expect(value as? Bool == false)
    }
}

@MainActor private final class HighlightFixtureBridge: NSObject, WKScriptMessageHandler {
    weak var receiver: WebHighlighterController?
    var documentID = ""
    var url = ""
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        receiver?.userContentController(userContentController, didReceive: message)
        if let body = message.body as? [String: Any], body["kind"] as? String == "ready" {
            documentID = body["documentID"] as? String ?? ""; url = body["url"] as? String ?? ""
        }
    }
}
@MainActor private final class Fixture {
    let web: WKWebView
    let bridge = HighlightFixtureBridge()
    init(html: String, controller: WebHighlighterController? = nil, manager: HighlightManager? = nil) async throws {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: CGRect(x: 0,y: 0,width: 800,height: 600), configuration: config)
        controller?.webView = web; controller?.manager = manager; controller?.allowed = { true }
        bridge.receiver = controller
        config.userContentController.add(bridge, contentWorld: HighlightScript.world, name: "origamiHighlight")
        config.userContentController.addUserScript(WKUserScript(source: HighlightScript.source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: HighlightScript.world))
        web.loadHTMLString("<html><body>" + html + "</body></html>", baseURL: URL(string: "https://example.invalid/article"))
        for _ in 0..<150 {
            if !bridge.documentID.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!bridge.documentID.isEmpty)
        try await configure()
    }
    func dispose() { web.stopLoading(); web.configuration.userContentController.removeScriptMessageHandler(forName: "origamiHighlight", contentWorld: HighlightScript.world) }
    func js(_ source: String) async throws -> Any? { try await web.callAsyncJavaScript(source, arguments: [:], in: nil, contentWorld: HighlightScript.world) }
    func select(_ selector: String) async throws -> [String: Any]? {
        try await web.callAsyncJavaScript("""
          const target=document.querySelector(selector), walk=document.createTreeWalker(target,NodeFilter.SHOW_TEXT), nodes=[];
          let n; while(n=walk.nextNode()) nodes.push(n);
          const range=document.createRange(); range.setStart(nodes[0],0); range.setEnd(nodes.at(-1),nodes.at(-1).length);
          getSelection().removeAllRanges(); getSelection().addRange(range);
          return window.__origamiHighlighter.selection();
        """, arguments: ["selector": selector], in: nil, contentWorld: HighlightScript.world) as? [String: Any]
    }
    func capture(_ selector: String) async throws -> [String: Any] {
        let value = try #require(try await select(selector)); return try #require(value["anchor"] as? [String: Any])
    }
    func resolve(_ anchor: [String: Any]) async throws -> String? {
        try await web.callAsyncJavaScript("return window.__origamiHighlighter.resolveAnchor(anchor)", arguments: ["anchor": anchor], in: nil, contentWorld: HighlightScript.world) as? String
    }
    func configure(anchor: [String: Any]? = nil, enabled: Bool = true) async throws {
        let records: [[String: Any]] = anchor.map { [["id": "fixture", "style": "yellow", "anchor": $0]] } ?? []
        _ = try await web.callAsyncJavaScript("window.__origamiHighlighter.configure(value)", arguments: ["value": ["documentID": bridge.documentID, "url": bridge.url, "records": records, "enabled": enabled]], in: nil, contentWorld: HighlightScript.world)
    }
}
