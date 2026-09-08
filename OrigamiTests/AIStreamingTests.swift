import Foundation
import Testing
@testable import Origami

@MainActor struct AIStreamingTests {
    @Test func requestsEnableStreamingAndSearchForEveryProvider() throws {
        for provider in AIProviderID.allCases {
            let input = AIRequest(query: "Question", mode: .ask, action: .web, contexts: [], model: "test")
            let request = try ProviderWire.streamingRequest(provider, input, "fixture")
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            #expect(body[provider == .openRouter ? "plugins" : "tools"] != nil)
            if provider == .gemini { #expect(request.url!.absoluteString.contains("streamGenerateContent?alt=sse")) }
            else { #expect(body["stream"] as? Bool == true) }
        }
    }
    @Test func responsesDeltasAndFinalCitations() throws {
        for provider in [AIProviderID.openAI, .xAI] {
            var stream = AIStreamAccumulator(provider: provider)
            try stream.consume(#"{"type":"response.output_text.delta","delta":"A fact."}"#)
            #expect(stream.partial.text == "A fact.")
            #expect(throws: (any Error).self) { try stream.result() }
            try stream.consume(#"{"type":"response.completed","response":{"output":[{"type":"message","content":[{"type":"output_text","text":"A fact.","annotations":[{"url":"https://example.com","title":"Source","start_index":0,"end_index":7}]}]}]}}"#)
            let result = try stream.result()
            #expect(result.citations.first?.excerpt == "A fact.")
        }
    }
    @Test func routerDeltasRetainAnnotationsAndRejectTruncation() throws {
        var stream = AIStreamAccumulator(provider: .openRouter)
        try stream.consume(#"{"choices":[{"delta":{"content":"A "}}]}"#)
        try stream.consume(#"{"choices":[{"delta":{"content":"fact.","annotations":[{"url_citation":{"url":"https://example.com","title":"Source","start_index":0,"end_index":7}}]},"finish_reason":"stop"}]}"#)
        try stream.consume("[DONE]")
        #expect(try stream.result().text == "A fact.")
        #expect(try stream.result().citations.count == 1)
        #expect(throws: (any Error).self) { try stream.consume(#"{"choices":[{"finish_reason":"length"}]}"#) }
    }
    @Test func routerFinalMessageRetainsRetrievalMetadata() throws {
        var stream = AIStreamAccumulator(provider: .openRouter)
        try stream.consume(#"{"choices":[{"delta":{"content":"Answer"}}]}"#)
        try stream.consume(#"{"choices":[{"message":{"annotations":[{"url_citation":{"url":"https://example.com/source","title":"Evidence"}}]},"finish_reason":"stop"}]}"#)
        #expect(stream.partial.sources.first?.url == "https://example.com/source")
        #expect(try stream.result().sources.first?.url == "https://example.com/source")
    }
    @Test func geminiChunksRetainGroundingAndIgnoreThoughts() throws {
        var stream = AIStreamAccumulator(provider: .gemini)
        try stream.consume(#"{"candidates":[{"content":{"parts":[{"text":"hidden","thought":true},{"text":"A "}]}}]}"#)
        try stream.consume(#"{"candidates":[{"content":{"parts":[{"text":"fact."}]},"finishReason":"STOP","groundingMetadata":{"groundingChunks":[{"web":{"uri":"https://example.com","title":"Source"}}],"groundingSupports":[{"segment":{"text":"A fact."},"groundingChunkIndices":[0]}]}}]}"#)
        #expect(try stream.result().text == "A fact.")
        #expect(try stream.result().citations.count == 1)
    }
}
