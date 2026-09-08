import Testing
import Foundation
import WebKit
import GRDB
@testable import Origami

@MainActor struct Phase3CTests {
    private func request(_ action: AIAction = .web, query: String = "Test") -> AIRequest { AIRequest(query: query, mode: .ask, action: action, contexts: [], model: "test-model") }
    @Test func providerRequestsKeepCredentialsInHeadersAndUseOnlyRetrievalTools() throws {
        for id in AIProviderID.allCases {
            let request = try ProviderWire.adapter(id).request(request(), credential: "sentinel-test-credential")
            #expect(!request.url!.absoluteString.contains("sentinel"))
            #expect(!String(data: request.httpBody!, encoding: .utf8)!.contains("sentinel"))
            #expect(request.url?.scheme == "https")
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            #expect(body[id == .openRouter ? "plugins" : "tools"] != nil)
            if id == .openAI || id == .xAI { #expect(body["store"] as? Bool == false) }
            let page = try ProviderWire.adapter(id).request(self.request(.summarize), credential: "test")
            let pageBody = try JSONSerialization.jsonObject(with: page.httpBody!) as! [String: Any]
            #expect(pageBody["tools"] == nil)
        }
    }
    @Test func allProvidersParseTheirOwnSources() throws {
        let samples: [(AIProviderID, String)] = [
            (.openAI, #"{"output":[{"type":"web_search_call"},{"type":"message","content":[{"type":"output_text","text":"A fact.","annotations":[{"type":"url_citation","url":"https://example.com/a","title":"Primary","start_index":0,"end_index":7}]}]}]}"#),
            (.xAI, #"{"output":[{"type":"message","content":[{"type":"output_text","text":"A fact.","annotations":[{"url":"https://example.com/a","title":"Primary","start_index":0,"end_index":7}]}]}],"citations":["https://example.com/a"]}"#),
            (.openRouter, #"{"choices":[{"message":{"content":"A fact.","annotations":[{"type":"url_citation","url_citation":{"url":"https://example.com/a","title":"Primary","start_index":0,"end_index":7}}]}}]}"#),
            (.gemini, #"{"candidates":[{"content":{"parts":[{"text":"A fact."}]},"groundingMetadata":{"webSearchQueries":["query"],"groundingChunks":[{"web":{"uri":"https://example.com/a","title":"Primary"}}],"groundingSupports":[{"segment":{"text":"A fact."},"groundingChunkIndices":[0]}]}}]}"#)
        ]
        for (provider, json) in samples {
            let result = try ProviderWire.adapter(provider).parse(Data(json.utf8))
            #expect(result.text == "A fact." && result.sources.count == 1)
            #expect(result.citations.first?.excerpt == "A fact.")
            let blocks = AnswerGrammar.blocks(result, contexts: [])
            #expect(blocks.first?.sourceURLs == ["https://example.com/a"])
        }
    }
    @Test func malformedAndUntrustedOutputCannotCreateVerifiedSources() throws {
        #expect(throws: (any Error).self) { try ProviderWire.parse(.openAI, Data("{bad".utf8)) }
        #expect(throws: (any Error).self) { try ProviderWire.parse(.openAI, Data(#"{"error":{"message":"SECRET"}}"#.utf8)) }
        #expect(AISource.safeURL("javascript:alert(1)") == nil)
        #expect(AISource.safeURL("origami://settings") == nil)
        #expect(AISource.safeURL("https://user:secret@example.com") == nil)
        let result = AIProviderResult(text: "Supported\n\nA claim [fake](https://invented.example)", sources: [], citations: [], searched: false)
        var event = AISearchEvent(query: "Claim", mode: .research, action: .verify, provider: .openAI, model: "model")
        AnswerGrammar.apply(result, to: &event, contexts: [])
        #expect(event.verification == .unknown && event.sources.isEmpty)
        #expect(event.blocks.allSatisfy { $0.sourceURLs.isEmpty })
        #expect(event.blocks.first?.kind == .callout)
    }
    @Test func eventStorageIsProfileScopedAndRestorable() throws {
        let db = try DatabaseManager(); let personal = try ProfileRepository(db).ensureDefault()
        let work = try ProfileRepository(db).create(name: "Work")
        let repository = AISearchRepository(db); let tab = UUID()
        var event = AISearchEvent(query: "Research topic", mode: .reference, action: .web, provider: .gemini, model: "model"); event.status = "Complete"
        try repository.save(event, profile: personal.id, tab: tab)
        #expect(try repository.event(tab: tab, profile: personal.id)?.query == "Research topic")
        #expect(try repository.event(tab: tab, profile: work.id) == nil)
        try repository.clear(profile: personal.id, since: .distantPast)
        #expect(try repository.event(tab: tab, profile: personal.id) == nil)
    }
    @Test func privateAnswersNeverReachSQLiteAndCancellationDoesNotOverwriteNewRequest() async throws {
        let db = try DatabaseManager(); let profile = try ProfileRepository(db).ensureDefault()
        let ai = AIController(database: db, isPrivate: true, client: FixtureAIClient())
        let tab = UUID()
        ai.start(request(query: "slow"), tab: tab, profile: profile.id)
        ai.start(request(query: "new"), tab: tab, profile: profile.id)
        try await Task.sleep(for: .milliseconds(150))
        #expect(ai.events[tab]?.query == "new" && ai.events[tab]?.status == "Complete")
        #expect(try ai.repository.list(profile: profile.id).isEmpty)
        ai.stop(); #expect(ai.events.isEmpty)
    }
    @Test func keychainRoundTripUsesIsolatedService() throws {
        let vault = AICredentialStore(service: "dev.origami.test." + UUID().uuidString)
        defer { try? vault.forget(.openAI) }
        try vault.save("sentinel-fake-key", provider: .openAI)
        #expect(vault.contains(.openAI))
        #expect(try vault.read(.openAI) == "sentinel-fake-key")
        try vault.save("updated-fake-key", provider: .openAI)
        #expect(try vault.read(.openAI) == "updated-fake-key")
        try vault.forget(.openAI); #expect(!vault.contains(.openAI))
    }
}
private struct FixtureAIClient: AIAnswerClient {
    func answer(provider: AIProviderID, input: AIRequest) async throws -> AIProviderResult {
        try await Task.sleep(for: .milliseconds(input.query == "slow" ? 100 : 5))
        return AIProviderResult(text: answerFixture(input.query, mode: input.mode), sources: [], citations: [], searched: false)
    }
}
