import Foundation
import Testing
@testable import Origami

@MainActor struct AskWorkflowTests {
    @Test func disabledPeekAndCredibilityRejectRequestsBeforeProviderAccess() async {
        for action in [AIAction.peek, .credibility] {
            let input = AIRequest(query: "Fixture", mode: .ask, action: action, contexts: [], model: "fixture")
            do {
                _ = try await NativeAIClient().answer(provider: .openRouter, input: input)
                Issue.record("Disabled AI action was allowed")
            } catch AIError.featureDisabled { } catch { Issue.record("Expected feature gate before provider access") }
            do {
                _ = try await NativeAIClient().stream(provider: .openRouter, input: input, update: { _ in Issue.record("Unexpected output") })
                Issue.record("Disabled AI stream was allowed")
            } catch AIError.featureDisabled { } catch { Issue.record("Expected feature gate before provider access") }
        }
    }

    @Test func aiPeekPreferencesPersistBehindDefaultOffFeatureFlag() throws {
        let name = "Origami.PeekPreferences." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AISettings(defaults: defaults)
        #expect(!settings.aiPeekEnabled && !settings.aiPeekSummary && !settings.aiPeekCredibility)
        settings.aiPeekSummary = true; settings.aiPeekCredibility = true
        #expect(!settings.aiPeekActive)
        settings.aiPeekEnabled = true
        let restored = AISettings(defaults: defaults)
        #expect(!AISettings.aiPeekAvailable && !restored.aiPeekActive)
        #expect(restored.aiPeekEnabled && restored.aiPeekSummary && restored.aiPeekCredibility)
        restored.aiPeekEnabled = false
        #expect(!restored.aiPeekActive && restored.aiPeekSummary && restored.aiPeekCredibility)
    }

    @Test func peekAndCredibilityUseConfiguredLightweightModel() throws {
        let name = "Origami.LightweightRoutingTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AISettings(defaults: defaults)
        settings.setModel("fixture/default", role: "primary")
        settings.setModel("fixture/light", role: "lightweight")
        settings.setModel("fixture/research", role: "research")
        #expect(settings.routedModel(action: .peek, mode: .ask) == "fixture/light")
        #expect(settings.routedModel(action: .credibility, mode: .research) == "fixture/light")
        #expect(AIAction.credibility.needsWeb)
        #expect(settings.routedModel(action: .web, mode: .research) == "fixture/research")
        settings.setModel("", role: "lightweight")
        #expect(settings.routedModel(action: .credibility, mode: .research) == "fixture/default")
    }

    @Test func modelCatalogLookupsReuseSnapshotAndRefreshAfterChanges() throws {
        let name = "Origami.ModelSearchTests." + UUID().uuidString
        let defaults = try #require(ModelSearchDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AISettings(defaults: defaults)
        settings.storeCatalog((0..<1000).map { ["id": "vendor/model-\($0)", "name": "Model \($0)"] })
        let models = settings.availableModels
        let reads = defaults.dictionaryReads
        for _ in 0..<3 {
            for id in models {
                _ = settings.displayName(id).localizedCaseInsensitiveContains("model")
                _ = settings.isFreeModel(id)
            }
        }
        #expect(defaults.dictionaryReads == reads)
        settings.storeCatalog([["id": "vendor/model-0", "name": "Updated name"]])
        #expect(settings.displayName("vendor/model-0") == "Updated name")
        settings.setFreeModels(["vendor/model-0"])
        #expect(settings.isFreeModel("vendor/model-0"))
        settings.provider = .gemini
        #expect(settings.availableModels.isEmpty)
        #expect(settings.displayName("vendor/model-0") == "model-0")
        #expect(!settings.isFreeModel("vendor/model-0"))
        settings.provider = .openRouter
        #expect(settings.displayName("vendor/model-0") == "Updated name")
    }
    @Test func setupRequiresVerificationAndExplicitModelChoice() throws {
        let name = "Origami.AISetupTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AISettings(defaults: defaults)
        #expect(settings.provider == .openRouter)
        #expect(!settings.setupComplete)
        settings.setVerified(true)
        #expect(!settings.setupComplete)
        settings.setModel("chosen-model", role: "primary")
        #expect(settings.setupComplete)
        settings.provider = .gemini
        #expect(!settings.setupComplete)
    }
    @Test func freeModelFilterRequiresKnownZeroPricing() throws {
        #expect(AISettings.isFreeOpenRouterModel(["id": "example/free", "pricing": ["prompt": "0", "completion": "0", "request": "0"]]))
        #expect(!AISettings.isFreeOpenRouterModel(["id": "example/paid", "pricing": ["prompt": "0", "completion": "0.001"]]))
        #expect(!AISettings.isFreeOpenRouterModel(["id": "example/unknown"]))
        #expect(!AISettings.isFreeOpenRouterModel(["id": "openrouter/auto", "pricing": ["prompt": "0", "completion": "0"]]))
        let name = "Origami.FreeModelsTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AISettings(defaults: defaults)
        settings.storeCatalog([["id": "vendor/model:free", "name": "Display Model", "pricing": ["prompt": 0, "completion": 0]]])
        #expect(settings.displayName("vendor/model:free") == "Display Model")
        #expect(settings.isFreeModel("vendor/model:free"))
        #expect(settings.isFreeModel("legacy/catalog:free"))
        #expect(!settings.isFreeModel("openrouter/auto"))
        settings.setFreeModels(["example/free"])
        let restored = AISettings(defaults: defaults)
        #expect(restored.freeModels == ["example/free"])
        restored.provider = .gemini
        #expect(restored.freeModels.isEmpty)
    }
    @Test func followUpsKeepOriginalSearchAndStayPrivate() async throws {
        for isPrivate in [false, true] {
            let db = try DatabaseManager(); let profile = try ProfileRepository(db).ensureDefault()
            let controller = AIController(database: db, isPrivate: isPrivate, client: WorkflowFixtureClient())
            let tab = UUID()
            controller.start(AIRequest(query: "Original question", mode: .ask, action: .web, contexts: [], model: "fixture"), tab: tab, profile: profile.id)
            try await wait { controller.events[tab]?.status == "Complete" }
            let id = controller.events[tab]?.id
            controller.followUp("Explain further", tab: tab, profile: profile.id, model: "fixture", mode: .research)
            try await wait { controller.events[tab]?.explorations?.last?.status == "Complete" }
            #expect(controller.events[tab]?.id == id)
            #expect(controller.events[tab]?.query == "Original question")
            #expect(controller.events[tab]?.mode == .ask)
            #expect(controller.events[tab]?.explorations?.last?.mode == .research)
            #expect(controller.events[tab]?.explorations?.last?.query == "Explain further")
            let saved = try controller.repository.list(profile: profile.id)
            #expect(saved.count == (isPrivate ? 0 : 1))
            if !isPrivate { #expect(saved.first?.explorations?.count == 1) }
            controller.stop()
        }
    }
    @Test func retryPreservesEvidenceAndReplacesFailedFollowUp() async throws {
        let db = try DatabaseManager(); let profile = try ProfileRepository(db).ensureDefault()
        let client = RetryFixtureClient()
        let controller = AIController(database: db, isPrivate: true, client: client)
        let tab = UUID()
        let context = AIPageContext(title: "Page", url: "https://example.com", text: "Original evidence")
        controller.start(AIRequest(query: "Root", mode: .ask, action: .page, contexts: [context], model: "fixture"), tab: tab, profile: profile.id)
        try await wait { controller.events[tab]?.status != "Requesting answer" }
        let failed = try #require(controller.events[tab])
        #expect(controller.canRetry(failed.id, tab: tab))
        controller.retry(failed.id, tab: tab, profile: profile.id)
        try await wait { controller.events[tab]?.status == "Complete" }
        #expect(client.requests.filter { $0.query == "Root" }.allSatisfy { $0.contexts == [context] })
        let rootID = try #require(controller.events[tab]?.id)
        controller.followUp("Follow", tab: tab, profile: profile.id, model: "fixture", mode: .research)
        try await wait { controller.events[tab]?.explorations?.last?.status != "Requesting answer" }
        let followID = try #require(controller.events[tab]?.explorations?.last?.id)
        controller.retry(followID, tab: tab, profile: profile.id)
        try await wait { controller.events[tab]?.explorations?.last?.status == "Complete" }
        #expect(controller.events[tab]?.id == rootID)
        #expect(controller.events[tab]?.explorations?.count == 1)
        #expect(controller.events[tab]?.explorations?.last?.mode == .research)
        #expect(try controller.repository.list(profile: profile.id).isEmpty)
        controller.stop()
        #expect(controller.events.isEmpty)
    }
    @Test func editsPreserveBranchesAndHistoryDeletionIsScoped() async throws {
        let db = try DatabaseManager(); let profile = try ProfileRepository(db).ensureDefault()
        let other = try ProfileRepository(db).create(name: "Other")
        let controller = AIController(database: db, isPrivate: false, client: WorkflowFixtureClient())
        let tab = UUID()
        controller.start(AIRequest(query: "Root", mode: .ask, action: .web, contexts: [], model: "fixture"), tab: tab, profile: profile.id)
        try await wait { controller.events[tab]?.status == "Complete" }
        controller.followUp("First", tab: tab, profile: profile.id, model: "fixture")
        try await wait { controller.events[tab]?.explorations?.last?.status == "Complete" }
        let originalID = try #require(controller.events[tab]?.explorations?.first?.id)
        controller.followUp("Later", tab: tab, profile: profile.id, model: "fixture")
        try await wait { controller.events[tab]?.explorations?.last?.status == "Complete" }
        controller.editFollowUp(originalID, query: "Edited", tab: tab, profile: profile.id, model: "fixture")
        try await wait { controller.events[tab]?.explorations?.last?.status == "Complete" }
        #expect(controller.events[tab]?.explorations?.count == 1)
        let edited = try #require(controller.events[tab]?.explorations?.first)
        #expect(edited.versions?.first?.query == "First")
        #expect(edited.versions?.first?.explorations?.first?.query == "Later")
        try controller.selectVersion(originalID, followUp: edited.id, tab: tab, profile: profile.id)
        #expect(controller.events[tab]?.explorations?.map(\.query) == ["First", "Later"])
        let restored = try #require(try controller.repository.event(tab: tab, profile: profile.id))
        #expect(restored.explorations?.first?.versions?.first?.query == "Edited")
        try controller.selectVersion(edited.id, followUp: originalID, tab: tab, profile: profile.id)
        #expect(controller.events[tab]?.explorations?.map(\.query) == ["Edited"])
        let rootID = try #require(controller.events[tab]?.id)
        try controller.deleteHistory(rootID, profile: other.id)
        #expect(try controller.repository.event(tab: tab, profile: profile.id) != nil)
        try controller.deleteHistory(rootID, profile: profile.id)
        #expect(controller.events[tab] == nil)
        #expect(try controller.repository.event(tab: tab, profile: profile.id) == nil)
        #expect(try controller.repository.list(profile: profile.id).isEmpty)
    }
    @Test func longAnswersDoNotCrowdOutRecentFollowUps() {
        var root = AISearchEvent(query: "Root", mode: .ask, action: .web, provider: .openRouter, model: "fixture")
        root.markdown = String(repeating: "Long root answer ", count: 5000)
        root.explorations = (1...5).map { index in
            var event = AISearchEvent(query: "Follow-up \(index)", mode: .ask, action: .web, provider: .openRouter, model: "fixture")
            event.status = "Complete"; event.markdown = String(repeating: "Long answer ", count: 5000)
            return event
        }
        let context = AIController.followUpContext(root)
        #expect(context.contains("Root"))
        #expect(context.contains("Follow-up 3") && context.contains("Follow-up 4") && context.contains("Follow-up 5"))
        #expect(!context.contains("Follow-up 1"))
        #expect(context.count < 24000)
    }
    private func wait(_ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(3)
        while !condition() { guard Date() < end else { throw AIError.response }; try await Task.sleep(for: .milliseconds(10)) }
    }
}
private struct WorkflowFixtureClient: AIAnswerClient {
    func answer(provider: AIProviderID, input: AIRequest) async throws -> AIProviderResult {
        if input.query == "Explain further" { #expect(input.evidencePayload.contains("Original question")) }
        return AIProviderResult(text: answerFixture(input.query, mode: input.mode), sources: [], citations: [], searched: false)
    }
}

@MainActor private final class RetryFixtureClient: AIAnswerClient {
    var requests: [AIRequest] = []
    func answer(provider: AIProviderID, input: AIRequest) async throws -> AIProviderResult {
        requests.append(input)
        if requests.filter({ $0.query == input.query }).count == 1 { throw AIError.http(503) }
        return AIProviderResult(text: answerFixture(input.query, mode: input.mode), sources: [], citations: [], searched: false)
    }
}

private final class ModelSearchDefaults: UserDefaults, @unchecked Sendable {
    var dictionaryReads = 0
    override func dictionary(forKey defaultName: String) -> [String: Any]? {
        dictionaryReads += 1
        return super.dictionary(forKey: defaultName)
    }
}
