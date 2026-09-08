import Foundation
import Testing
@testable import Origami

@MainActor struct AIFallbackTests {
    private func settings() -> AISettings {
        let defaults = UserDefaults(suiteName: "FallbackTests." + UUID().uuidString)!
        let settings = AISettings(defaults: defaults)
        settings.automaticFallback = true
        settings.setModel("backup", role: "fallback")
        settings.storeCatalog([["id": "backup", "name": "Backup Model", "supported_parameters": ["structured_outputs"], "context_length": 500000, "top_provider": ["max_completion_tokens": 32000]]])
        return settings
    }
    private var input: AIRequest { AIRequest(query: "Question", mode: .ask, action: .web, contexts: [], model: "research-primary") }
    @Test func temporaryFailuresRetryOnceAndPersistDisclosure() async throws {
        for error: Error in [AIError.http(429), AIError.http(503), URLError(.timedOut)] {
            let settings = settings(); let base = FallbackFixture(errors: [error])
            let result = try await FallbackAIClient(base: base, settings: settings).answer(provider: .openRouter, input: input)
            #expect(base.models == ["research-primary", "backup"])
            #expect(result.fallbackDisclosure == "Answered with Backup Model — default model was unavailable.")
            var event = AISearchEvent(query: input.query, mode: input.mode, action: input.action, provider: .openRouter, model: input.model)
            try AnswerProtocol.apply(result, to: &event, input: input)
            let restored = try JSONDecoder().decode(AISearchEvent.self, from: JSONEncoder().encode(event))
            #expect(restored.model == "backup" && restored.fallbackDisclosure == result.fallbackDisclosure)
        }
    }
    @Test func permanentErrorsNeverRetry() async {
        for error in [AIError.credential, .http(401), .nonRetryable(402), .nonRetryable(429), .answerSchema, .invalidJSON, .truncated, .nonRetryable(400), .response] {
            let base = FallbackFixture(errors: [error])
            do { _ = try await FallbackAIClient(base: base, settings: settings()).answer(provider: .openRouter, input: input); Issue.record("Expected error") }
            catch { #expect(error.localizedDescription == (base.errors[0] as NSError).localizedDescription) }
            #expect(base.models.count == 1)
        }
    }
    @Test func disabledReturnsOriginalError() async {
        let settings = settings(); settings.automaticFallback = false
        let base = FallbackFixture(errors: [AIError.http(503)])
        do { _ = try await FallbackAIClient(base: base, settings: settings).answer(provider: .openRouter, input: input); Issue.record("Expected error") }
        catch { #expect(error.localizedDescription == AIError.http(503).localizedDescription) }
        #expect(base.models.count == 1)
    }
    @Test func missingOrIncompatibleFallbackDoesNotRetry() async {
        for model in ["", "unknown", "research-primary"] {
            let settings = settings(); settings.setModel(model, role: "fallback")
            let base = FallbackFixture(errors: [AIError.http(503)])
            do { _ = try await FallbackAIClient(base: base, settings: settings).answer(provider: .openRouter, input: input); Issue.record("Expected error") }
            catch { #expect(error.localizedDescription == AIError.noCompatibleFallback.localizedDescription) }
            #expect(base.models.count == 1)
        }
    }
    @Test func failedFallbackNeverRetriesAgain() async {
        let base = FallbackFixture(errors: [AIError.http(503), AIError.http(429)])
        do { _ = try await FallbackAIClient(base: base, settings: settings()).answer(provider: .openRouter, input: input); Issue.record("Expected error") }
        catch { #expect(error.localizedDescription == AIError.http(429).localizedDescription) }
        #expect(base.models.count == 2)
    }
    @Test func errorBodyOverridesAvailabilityStatus() {
        for message in ["insufficient credits", "unsupported parameter", "context length exceeded", "invalid API key", "schema error", "safety refusal", "insufficient_quota"] {
            #expect(!AIAvailability.temporary(AIAvailability.error(status: 429, body: Data(message.utf8))))
        }
        #expect(AIAvailability.temporary(AIAvailability.error(status: 404, body: Data("No endpoints found: route unavailable".utf8))))
        #expect(!AIAvailability.temporary(AIAvailability.error(status: 404, body: Data("No endpoints support response_format".utf8))))
        #expect(AIAvailability.temporary(AIAvailability.error(status: 503, body: Data())))
    }
    @Test func capabilitiesPreserveModeVisualsAndSearch() async throws {
        let settings = settings(); var request = input
        request.mode = .research; request.generatedVisuals = true; request.searchEngine = "exa"
        let base = FallbackFixture(errors: [AIError.http(503)])
        _ = try await FallbackAIClient(base: base, settings: settings).answer(provider: .openRouter, input: request)
        #expect(base.requests[1].mode == .research && base.requests[1].generatedVisuals)
        #expect(base.requests[1].action.needsWeb && base.requests[1].searchEngine == "exa")
        settings.storeCatalog([["id":"backup", "supported_parameters":["structured_outputs"], "context_length":500000, "top_provider":["max_completion_tokens":1000]]])
        // A different request cannot borrow a previous capability confirmation.
        request.mode = .reference
        #expect(!settings.fallbackCompatible("backup", provider: .openRouter, input: request))
        #expect(!settings.fallbackCompatible("unverified", provider: .gemini, input: request))
    }
    @Test func nativeProviderCompatibilityRequiresMatchingRecentSuccess() throws {
        let settings = settings(); let request = input
        let result = AIProviderResult(text: answerFixture(), sources: [], citations: [], searched: true)
        for provider in [AIProviderID.openAI, .gemini, .xAI] {
            var backup = request; backup.model = "backup"
            #expect(!settings.fallbackCompatible("backup", provider: provider, input: request))
            settings.rememberCompatibility(provider: provider, input: backup, result: result)
            #expect(settings.fallbackCompatible("backup", provider: provider, input: request))
            backup.generatedVisuals = true
            #expect(!settings.fallbackCompatible("backup", provider: provider, input: backup))
            backup.generatedVisuals = false; backup.searchEngine = "different"
            #expect(!settings.fallbackCompatible("backup", provider: provider, input: backup))
        }
    }
    @Test func streamedProviderErrorsUseSameClassification() throws {
        var stream = AIStreamAccumulator(provider: .openRouter)
        do { try stream.consume(#"{"error":{"code":429,"message":"capacity limit"}}"#); Issue.record("Expected error") }
        catch { #expect(AIAvailability.temporary(error)) }
        do { try stream.consume(#"{"error":{"code":429,"message":"insufficient credits"}}"#); Issue.record("Expected error") }
        catch { #expect(!AIAvailability.temporary(error)) }
    }
    @Test func successfulPrimaryDoesNotUseFallbackOrDisclose() async throws {
        let base = FallbackFixture(errors: [])
        let result = try await FallbackAIClient(base: base, settings: settings()).answer(provider: .openRouter, input: input)
        #expect(base.models == [input.model])
        #expect(result.fallbackDisclosure == nil && result.answeredModel == nil)
    }
    @Test func malformedSuccessIsNotAvailabilityFailure() async {
        let base = FallbackFixture(errors: [], malformed: true)
        do { _ = try await FallbackAIClient(base: base, settings: settings()).answer(provider: .openRouter, input: input); Issue.record("Expected schema failure") }
        catch { #expect(!AIAvailability.temporary(error)) }
        #expect(base.models.count == 1)
    }
}
@MainActor private final class FallbackFixture: AIAnswerClient {
    let errors: [Error]
    let malformed: Bool
    var requests: [AIRequest] = []
    var models: [String] { requests.map(\.model) }
    init(errors: [Error], malformed: Bool = false) { self.errors = errors; self.malformed = malformed }
    func answer(provider: AIProviderID, input: AIRequest) async throws -> AIProviderResult {
        requests.append(input)
        if requests.count <= errors.count { throw errors[requests.count - 1] }
        return AIProviderResult(text: malformed ? "invalid" : answerFixture(input.query, mode: input.mode), sources: [], citations: [], searched: true)
    }
}
