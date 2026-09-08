import Foundation
import AppKit
import Testing
@testable import Origami

private actor ControlledSuggestions: RemoteSuggestionProvider {
    var requests: [String] = []
    var pending: [String: CheckedContinuation<[String], Error>] = [:]
    func suggestions(for query: String) async throws -> [String] {
        requests.append(query)
        return try await withCheckedThrowingContinuation { pending[query] = $0 }
    }
    func finish(_ query: String, values: [String]) { pending.removeValue(forKey: query)?.resume(returning: values) }
    func fail(_ query: String) { pending.removeValue(forKey: query)?.resume(throwing: URLError(.notConnectedToInternet)) }
}

@MainActor struct SuggestionTests {
    @Test func suggestionsAreBoundedAndDeduplicateSitesAndQueries() async throws {
        #expect(SuggestionEngine.destinationKey("http://www.apple.com/") == SuggestionEngine.destinationKey("https://apple.com"))
        #expect(SuggestionEngine.destinationKey("https://example.com/Docs") != SuggestionEngine.destinationKey("https://example.com/docs"))
        let remote = ControlledSuggestions()
        let engine = SuggestionEngine(remote: remote)
        engine.update("apple", bookmarks: nil, engine: .google, allowRemote: true)
        try await wait { await remote.requests.contains("apple") }
        await remote.finish("apple", values: ["apple", "APPLE", "apple.com", "apple watch", "Apple  Watch", "apple store", "apple support", "apple news", "apple music"])
        try await wait { engine.results.contains { $0.title == "apple watch" } }
        #expect(engine.results.count <= 6)
        let queries = engine.results.filter { $0.kind == .remoteSearch }.map { SuggestionEngine.queryKey($0.input) }
        #expect(Set(queries).count == queries.count)
        #expect(!queries.contains("apple"))
        #expect(!queries.contains("apple.com"))
        #expect(engine.results.last?.kind == .directSearch)
        engine.stop()
    }

    @Test func commonSitesAreCuratedAndMatchPrefixesAndAliases() {
        #expect((95...110).contains(CommonSites.all.count))
        #expect(Set(CommonSites.all.map(\.domain)).count == CommonSites.all.count)
        let provider = CommonSiteSuggestionProvider()
        #expect(provider.suggestions(for: "you").contains { $0.title == "YouTube" })
        #expect(provider.suggestions(for: "yt").contains { $0.title == "YouTube" })
        #expect(provider.suggestions(for: "git").contains { $0.title == "GitHub" })
        #expect(provider.suggestions(for: "github.com").contains { $0.title == "GitHub" })
        #expect(provider.suggestions(for: "nothing-like-a-common-site").isEmpty)
    }
    @Test func bookmarksMatchTitleURLFolderAndRankAboveComparableSites() throws {
        let database = try DatabaseManager()
        let profiles = ProfileRepository(database)
        let profile = try profiles.ensureDefault()
        let other = try profiles.create(name: "Other")
        let repository = BookmarkRepository(database)
        let folder = try repository.createFolder(title: "Development", profileID: profile.id)
        try repository.create(url: URL(string: "https://developer.apple.com/documentation/")!, title: "Apple Developer Documentation", folderID: folder, profileID: profile.id)
        try repository.create(url: URL(string: "https://github.com/")!, title: "GitHub Projects", profileID: profile.id)
        try repository.create(url: URL(string: "https://secret.invalid")!, title: "Secret", profileID: other.id)
        let provider = BookmarkSuggestionProvider(repository: repository, profileID: profile.id)
        #expect(provider.suggestions(for: "apple dev").first?.title == "Apple Developer Documentation")
        #expect(provider.suggestions(for: "developer.apple.com").count == 1)
        #expect(provider.suggestions(for: "documentation").count == 1)
        #expect(provider.suggestions(for: "development").count == 1)
        #expect(provider.suggestions(for: "secret").isEmpty)
        #expect(provider.suggestions(for: "%").isEmpty)
        let engine = SuggestionEngine()
        engine.update("git", bookmarks: provider, engine: .bing, allowRemote: false)
        #expect(engine.results.first?.kind == .bookmark)
        #expect(engine.results.last?.title == "Search Bing for “git”")
        #expect(engine.results.filter { $0.input.contains("github.com") }.count == 1)
        engine.moveSelection(1)
        #expect(engine.selected?.kind == .bookmark)
        engine.moveSelection(-1)
        #expect(engine.selected?.kind == .directSearch)
        engine.stop()
        #expect(engine.results.isEmpty && engine.selected == nil)
    }
    @Test func nativeFieldCommandsSelectActivateAndDismissSuggestions() async throws {
        let store = BrowserStore()
        var submitted: [(String, Bool)] = []
        let omnibox = Omnibox(store: store, allowRemote: false, tabID: nil, value: "", focusRequest: UUID()) { submitted.append(($0, $1)) }
        let coordinator = omnibox.makeCoordinator()
        let field = AddressField(), editor = NSTextView()
        field.stringValue = "git"
        coordinator.field = field
        coordinator.suggestions.update("git", bookmarks: nil, engine: .google, allowRemote: false)
        #expect(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        #expect(coordinator.suggestions.selected != nil)
        #expect(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(submitted.isEmpty)
        try await wait { submitted.count == 1 }
        #expect(submitted.count == 1 && submitted[0].0.hasPrefix("https://") && !submitted[0].1)
        coordinator.suggestions.update("git", bookmarks: nil, engine: .google, allowRemote: false)
        #expect(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(coordinator.suggestions.results.isEmpty)
        #expect(field.stringValue == "git")
        #expect(submitted.count == 1)
    }
    @Test func braveParsingRejectsMalformedAndBoundsValues() {
        #expect(BraveSuggestionProvider.parse(Data(#"["swift",["swift ui","swift actor",12,"","SWIFT UI"]]"#.utf8)) == ["swift ui", "swift actor"])
        for text in ["{}", "[]", #"["swift",{}]"#, "broken"] {
            #expect(BraveSuggestionProvider.parse(Data(text.utf8)).isEmpty)
        }
        #expect(BraveSuggestionProvider.parse(Data(repeating: 32, count: 70_000)).isEmpty)
    }
    @Test func staleResponsesCannotReplaceNewQueryAndLocalsAppearImmediately() async throws {
        let remote = ControlledSuggestions()
        let subject = SuggestionEngine(remote: remote)
        subject.update("git", bookmarks: nil, engine: .google, allowRemote: true)
        #expect(subject.results.contains { $0.title == "GitHub" })
        try await wait { await remote.requests.contains("git") }
        subject.update("you", bookmarks: nil, engine: .google, allowRemote: true)
        #expect(subject.results.contains { $0.title == "YouTube" })
        try await wait { await remote.requests.contains("you") }
        await remote.finish("you", values: ["youtube music"])
        try await wait { subject.results.contains { $0.title == "youtube music" } }
        await remote.finish("git", values: ["stale result"])
        try await Task.sleep(for: .milliseconds(30))
        #expect(!subject.results.contains { $0.title == "stale result" })
        subject.stop()
    }
    @Test func debounceCancellationFailureAndDisabledRemoteRemainLocal() async throws {
        let remote = ControlledSuggestions()
        let engine = SuggestionEngine(remote: remote)
        engine.update("g", bookmarks: nil, engine: .brave, allowRemote: true)
        engine.update("gi", bookmarks: nil, engine: .brave, allowRemote: true)
        engine.update("git", bookmarks: nil, engine: .brave, allowRemote: false)
        try await Task.sleep(for: .milliseconds(220))
        #expect(await remote.requests.isEmpty)
        #expect(engine.results.contains { $0.title == "GitHub" })
        engine.update("git", bookmarks: nil, engine: .brave, allowRemote: true)
        try await wait { await remote.requests.contains("git") }
        await remote.fail("git")
        try await Task.sleep(for: .milliseconds(30))
        #expect(engine.results.contains { $0.title == "GitHub" })
        #expect(!engine.results.contains { $0.kind == .remoteSearch })
        engine.update("", bookmarks: nil, engine: .brave, allowRemote: true)
        #expect(engine.results.isEmpty)
        for query in ["https://example.com/token", "origami://history", "name@example.com", "/tmp/private", "localhost:8000"] {
            #expect(!SuggestionEngine.canSendRemotely(query))
        }
    }
    private func wait(_ condition: () async -> Bool) async throws {
        for _ in 0..<100 { if await condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        Issue.record("Suggestion task did not finish")
    }
}
