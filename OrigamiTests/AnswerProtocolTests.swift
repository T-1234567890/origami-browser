import Foundation
import Testing
import SwiftUI
import WebKit
@testable import Origami

func answerFixture(_ query: String = "Question", mode: AskMode = .ask, blocks: [[String: Any]] = [["type":"paragraph","text":"A fact.","citations":["src_1"]]]) -> String {
    let source: [String: Any] = ["id":"src_1", "url":"https://example.com", "canonical_url":NSNull(), "title":"Source", "publisher":NSNull(), "author":NSNull(), "published_at":NSNull(), "updated_at":NSNull(), "source_type":"primary", "provenance":NSNull()]
    let root: [String: Any] = ["schema_version":1, "query":query, "mode":mode.rawValue.lowercased(), "summary":"Summary", "sources":[source], "blocks":blocks]
    return String(data: try! JSONSerialization.data(withJSONObject: root), encoding: .utf8)!
}
@MainActor struct AnswerProtocolTests {
    @Test func credibilityNeedsIndependentProviderEvidence() throws {
        let context = AIPageContext(title: "Page", url: "https://page.example", text: "Excerpt")
        let input = AIRequest(query: "Evaluate", mode: .research, action: .credibility, contexts: [context], model: "fixture")
        let text = answerFixture(mode: .research).replacingOccurrences(of: "Summary", with: "Credible. Evidence supports the source.")
        for sources in [[], [AISource(url: context.url, title: "Page", provenance: "Provider retrieval")], [AISource(url: "https://example.com", title: "Independent source", provenance: "Provider retrieval")]] {
            var event = AISearchEvent(query: "Evaluate", mode: .research, action: .credibility, provider: .openRouter, model: "fixture")
            try AnswerProtocol.apply(AIProviderResult(text: text, sources: sources, citations: [], searched: true), to: &event, input: input)
            #expect(event.credibility == (sources.last?.url == "https://example.com" ? .credible : .unknown))
            #expect(event.answerV1?.blocks.isEmpty == false)
        }
        #expect(input.systemInstruction.contains("Do not give a numerical credibility score"))
    }

    @Test func miniMaxFreeUsesCatalogJSONMode() throws {
        let name = "Origami.protocol.catalog." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AISettings(defaults: defaults)
        let id = "minimax/minimax-m3:free"
        settings.storeCatalog([["id":id, "supported_parameters":["response_format", "tools"]]])
        #expect(settings.needsJSONMode(id))
        var input = AIRequest(query:"Q", mode:.ask, action:.web, contexts:[], model:id)
        input.jsonOnlyFallback = settings.needsJSONMode(id)
        let request = try ProviderWire.streamingRequest(.openRouter, input, "fixture")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String:Any]
        #expect((body["response_format"] as? [String:Any])?["type"] as? String == "json_object")
        #expect((body["plugins"] as? [[String: Any]])?.first?["id"] as? String == "web")
        settings.storeCatalog([["id":id, "supported_parameters":["response_format", "structured_outputs"]]])
        #expect(!settings.needsJSONMode(id))
    }
    @Test func everyBlockAndExplicitReferences() throws {
        let item: [String:Any] = ["text":"Item", "citations":["src_1","missing"]]
        let blocks: [[String:Any]] = [
            ["type":"heading","text":"Heading","level":2], ["type":"paragraph","text":"A fact","citations":["missing","src_1"]],
            ["type":"bullets","items":[item]], ["type":"numbered_list","items":[item]], ["type":"steps","items":[item]],
            ["type":"table","title":"Table","columns":["Column"],"rows":[["Cell"]],"citations":["src_1"]],
            ["type":"comparison","title":"Compare","items":[["label":"A","text":"Detail","citations":["src_1"]]]],
            ["type":"timeline","title":"Timeline","items":[["date":"2003","label":"Event","citations":["src_1"]]]],
            ["type":"quote","text":"Quote","attribution":NSNull(),"citations":["src_1"]],
            ["type":"code","language":"swift","code":"print(1)","citations":[]], ["type":"callout","text":"Note","citations":[]],
            ["type":"generated_visual","title":"Demo","html":"<div><p>Example visual</p></div>","css":"p {height:80px}","javascript":""]
        ]
        let answer = try AnswerProtocol.decode(answerFixture(blocks: blocks), visuals: true)
        #expect(answer.schema_version == 1 && answer.blocks.count == 12)
        #expect(answer.sourceNumber("src_1") == 1 && answer.sourceNumber("missing") == nil)
        #expect(answer.sources.first?.publisher == nil)
        if case .paragraph(let text) = answer.blocks[1] { #expect(text.citations == ["src_1"]) } else { Issue.record("Wrong block") }
        #expect(try AnswerProtocol.decode(answerFixture(blocks: blocks), visuals: false).blocks.count == 11)
        let stored = try JSONEncoder().encode(answer)
        #expect(try JSONDecoder().decode(OrigamiAnswerV1.self, from: stored) == answer)
    }
    @Test func malformedContractsDoNotBecomeMarkdown() throws {
        for text in ["# An answer", "{bad", answerFixture().replacingOccurrences(of: "\"schema_version\":1", with: "\"schema_version\":2"), answerFixture(blocks: [["type":"unknown"]]), answerFixture(blocks: [["type":"paragraph","citations":[]]]), answerFixture(blocks: [["type":"table","title":"T","columns":["A"],"rows":[["a","b"]],"citations":[]]])] {
            #expect(throws: (any Error).self) { try AnswerProtocol.decode(text, visuals: false) }
        }
    }
    @Test func invalidVisualRetainsFailureLocationWithoutLosingAnswer() throws {
        let visual: [String:Any] = ["type":"generated_visual", "title":"Bad", "html":"<iframe src=\"https://example.com\"></iframe>", "css":"", "javascript":""]
        let answer = try AnswerProtocol.decode(answerFixture(blocks: [["type":"heading", "text":"Interactive Visualization", "level":2], visual, ["type":"paragraph", "text":"Still visible", "citations":[]]]), visuals: true)
        #expect(answer.blocks.count == 3)
        if case .generated_visual(let rejected) = answer.blocks[1] { #expect(rejected.html.isEmpty) } else { Issue.record("Missing visual failure location") }
        #expect(answer.blocks[2].plainText == "Still visible")
        #expect(try AnswerProtocol.decode(answerFixture(blocks: [["type":"generated_visual"]]), visuals: true).summary == "Summary")
    }
    @Test func systemRolesSchemaAndVisualPolicies() throws {
        for provider in AIProviderID.allCases {
            var input = AIRequest(query:"SECRET_QUERY",mode:.research,action:.web,contexts:[AIPageContext(title:"P",url:"https://example.com",text:"UNTRUSTED_SENTINEL")],model:"test")
            #expect(!input.systemInstruction.contains("SECRET_QUERY") && !input.systemInstruction.contains("UNTRUSTED_SENTINEL"))
            #expect(!input.systemInstruction.contains("GENERATED VISUALS") && !input.systemInstruction.contains("generated_visual"))
            input.generatedVisuals = true
            #expect(input.systemInstruction.contains("GENERATED VISUALS ON") && input.systemInstruction.contains("Interactive visuals"))
            let request = try ProviderWire.request(provider,input,"fake")
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String:Any]
            if provider == .openRouter { #expect(body["response_format"] != nil && (body["messages"] as? [[String:Any]])?.first?["role"] as? String == "system") }
            else if provider == .gemini { #expect(body["systemInstruction"] != nil && (body["generationConfig"] as? [String:Any])?["responseJsonSchema"] != nil) }
            else { #expect(body["instructions"] != nil && body["text"] != nil) }
        }
    }
    @Test func retrievedSourcesSurviveMissingModelReferences() throws {
        let input = AIRequest(query: "Q", mode: .ask, action: .web, contexts: [], model: "fixture")
        var event = AISearchEvent(query: "Q", mode: .ask, action: .web, provider: .openRouter, model: "fixture")
        let result = AIProviderResult(text: answerFixture(), sources: [AISource(url: "https://example.com/retrieved", title: "Retrieved", provenance: "Provider")], citations: [], searched: true)
        try AnswerProtocol.apply(result, to: &event, input: input)
        #expect(event.answerV1?.sources.first?.url == "https://example.com/retrieved")
        #expect(event.answerV1?.sources.first?.provenance?.contains("not linked") == true)
        if case .paragraph(let value) = event.answerV1?.blocks.first { #expect(value.citations.isEmpty) }
        var empty = result; empty.sources = []
        try AnswerProtocol.apply(empty, to: &event, input: input, isFinal: false)
        #expect(event.answerV1?.blocks.count == 1)
        try AnswerProtocol.apply(empty, to: &event, input: input)
        #expect(event.answerV1?.blocks.count == 2)
    }
    @Test func modernMappingDoesNotUseExcerptMatching() throws {
        let input = AIRequest(query:"Q",mode:.ask,action:.web,contexts:[],model:"fixture")
        let result = AIProviderResult(text:answerFixture("Q"),sources:[AISource(url:"https://example.com",title:"S",provenance:"Provider")],citations:[AICitation(sourceURL:"https://example.com",excerpt:"UNRELATED",startIndex:10,endIndex:20)],searched:true)
        var event = AISearchEvent(query:"Q",mode:.ask,action:.web,provider:.openAI,model:"fixture")
        try AnswerProtocol.apply(result,to:&event,input:input)
        #expect(event.blocks.isEmpty && event.markdown == nil)
        #expect(event.citations.first?.startIndex == 10)
        #expect(event.answerV1?.sourceNumber("src_1") == 1)
    }
}

@MainActor struct VisualProtocolTests {
    @Test func visualConfigurationAndAdmission() {
        let config = VisualPolicy.configuration()
        #expect(!config.websiteDataStore.isPersistent)
        #expect(!config.preferences.javaScriptCanOpenWindowsAutomatically)
        #expect(config.userContentController.userScripts.count == 1)
        for html in ["<script>alert(1)</script>", "<iframe></iframe>", "<form></form>", "<div onclick=\"evil()\">Test</div>", "<img src=\"origami://settings\"/>"] {
            #expect(!VisualPolicy.valid(AnswerVisual(title:"V",html:html,css:"",javascript:"")))
        }
        #expect(!VisualPolicy.valid(AnswerVisual(title:"V",html:"<div>Test</div>",css:"@import 'https://example.com';",javascript:"")))
        #expect(!VisualPolicy.valid(AnswerVisual(title:"V",html:"<div>Test</div>",css:"",javascript:"while(true){}")))
        #expect(VisualPolicy.valid(AnswerVisual(title:"V",html:"<div>Test</div>",css:"div {height:80px}",javascript:"document.querySelector('div').textContent='Example';")))
        #expect(VisualPolicy.rejection(AnswerVisual(title:"V",html:"<svg></svg>",css:"",javascript:"")) == "html.unsupported_tag")
        #expect(VisualPolicy.rejection(AnswerVisual(title:"V",html:"<div>Test</div>",css:"@import 'remote';",javascript:""))?.hasPrefix("css.") == true)
        #expect(VisualPolicy.rejection(AnswerVisual(title:"V",html:"<div>Test</div>",css:"",javascript:"fetch('remote')"))?.hasPrefix("javascript.") == true)
    }
    @Test func failedVisualNeverReservesHeight() {
        var height: CGFloat = 0
        var failure = false
        let coordinator = VisualWebHost.Coordinator(height: Binding(get: { height }, set: { height = $0 }), failure: Binding(get: { failure }, set: { failure = $0 }))
        #expect(height == 0)
        coordinator.accept(["failed":false,"height":80.0,"text":10,"canvas":false])
        #expect(height == 80)
        coordinator.accept(["failed":true,"height":80.0,"text":10])
        #expect(height == 0 && failure)
        coordinator.accept(["failed":false,"height":80.0,"text":10])
        #expect(height == 0)
    }
    @Test func terminationAndTimeoutCollapseVisual() {
        for timeout in [false,true] {
            var height: CGFloat = 80
            let coordinator = VisualWebHost.Coordinator(height: Binding(get: { height }, set: { height = $0 }))
            if timeout { coordinator.started = Date.distantPast; coordinator.check() }
            else { coordinator.webViewWebContentProcessDidTerminate(WKWebView(frame:.zero,configuration:VisualPolicy.configuration())) }
            #expect(height == 0 && coordinator.failed)
        }
    }
    @Test func actualWebKitRuntimeFailureHidesVisual() async throws {
        var height: CGFloat = 0
        let coordinator = VisualWebHost.Coordinator(height: Binding(get: { height }, set: { height = $0 }))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 480), configuration: VisualPolicy.configuration())
        coordinator.web = web; web.navigationDelegate = coordinator
        defer { coordinator.fail() }
        web.loadHTMLString(VisualPolicy.document(AnswerVisual(title: "Fixture", html: "<div>Useful diagram explanation</div>", css: "#visual {height:80px}", javascript: "")), baseURL: nil)
        coordinator.start()
        for _ in 0..<60 {
            if height > 0 || coordinator.failed { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(height == 80 && !coordinator.failed)
        let bridge = try await web.evaluateJavaScript("Boolean(window.webkit && window.webkit.messageHandlers)")
        #expect(bridge as? Bool == false)
        _ = try await web.evaluateJavaScript("setTimeout(() => { throw new Error('fixture failure'); }, 0); 0")
        for _ in 0..<20 {
            if coordinator.failed { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(coordinator.failed && height == 0)
    }
    @Test func legacyStoredEventStillDecodes() throws {
        var event = AISearchEvent(query:"Old",mode:.ask,action:.web,provider:.openAI,model:"old")
        event.blocks = [AIBlock(kind:.prose,text:"Saved answer")]
        let data = try JSONEncoder().encode(event)
        let restored = try JSONDecoder().decode(AISearchEvent.self,from:data)
        #expect(restored.answerV1 == nil && restored.blocks.first?.text == "Saved answer")
    }
}
