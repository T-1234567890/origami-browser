import Testing
import WebKit
@testable import Origami

@MainActor struct WebPageFindTests {
    @Test func liveQueriesKeepIndependentHighlights() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        web.loadHTMLString("<title>Find fixture</title><p>Git<b>Hub</b> GitHub</p><p hidden>GitHub</p><input value='GitHub'><p>Literal .* text</p>", baseURL: URL(string: "https://example.invalid"))
        defer { web.stopLoading() }
        for _ in 0..<100 {
            if web.title == "Find fixture", !web.isLoading { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(try await WebPageFind.update(web, query: "git") == 2)
        #expect(try await WebPageFind.update(web, query: "github") == 2)
        #expect(try await WebPageFind.update(web, query: "github", step: 1) == 2)
        _ = try await web.evaluateJavaScript("window.getSelection().removeAllRanges(); document.body.click()")
        let state = try await web.callAsyncJavaScript("return [...CSS.highlights.values()].map(h => [...h].map(r => r.toString()));", arguments: [:], in: nil, contentWorld: WebPageFind.world) as? [[String]]
        #expect(state?.count == 2)
        #expect(state?.first == ["GitHub", "GitHub"])
        #expect(state?.last == ["GitHub"])
        #expect(try await WebPageFind.update(web, query: ".*") == 1)
        #expect(try await WebPageFind.update(web, query: "nothing") == 0)
        #expect(try await WebPageFind.update(web, query: "") == 0)
        let count = try await web.callAsyncJavaScript("return CSS.highlights.size", arguments: [:], in: nil, contentWorld: WebPageFind.world) as? Int
        #expect(count == 0)
    }
}
