import Foundation
import Observation

struct Suggestion: Identifiable, Equatable {
    enum Kind { case commonSite, bookmark, remoteSearch, directSearch }
    let id: String
    let kind: Kind
    let title: String
    let detail: String
    let input: String
    let score: Int
    var isSearch: Bool { kind == .remoteSearch || kind == .directSearch }
}

enum SuggestionMatch {
    static func quality(_ query: String, fields: [String]) -> Int {
        let fields = fields.map { $0.lowercased().replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "") }
        if fields.contains(query) { return 30 }
        if fields.contains(where: { $0.hasPrefix(query) || $0.replacingOccurrences(of: "www.", with: "").hasPrefix(query) }) { return 20 }
        let words = query.split(whereSeparator: \.isWhitespace)
        if !words.isEmpty && words.allSatisfy({ word in fields.contains { $0.contains(word) } }) { return 10 }
        return 0
    }
}

struct CommonSiteSuggestionProvider {
    func suggestions(for query: String) -> [Suggestion] {
        CommonSites.all.compactMap { site in
            let quality = SuggestionMatch.quality(query, fields: [site.name, site.domain] + site.aliases)
            guard quality > 0 else { return nil }
            return Suggestion(id: "site:" + site.domain, kind: .commonSite, title: site.name, detail: site.detail ?? site.domain,
                              input: "https://" + site.domain, score: (quality >= 20 ? 300 : 100) + quality)
        }
    }
}

struct BookmarkSuggestionProvider {
    let repository: BookmarkRepository
    let profileID: UUID
    func suggestions(for query: String) -> [Suggestion] {
        // Read the existing repository, without a second cache or search database.
        guard let bookmarks = try? repository.suggestionCandidates(query: query, profileID: profileID) else { return [] }
        return bookmarks.compactMap { bookmark, folder in
            let quality = SuggestionMatch.quality(query, fields: [bookmark.title, bookmark.url, folder])
            guard quality > 0 else { return nil }
            return Suggestion(id: "bookmark:" + bookmark.id.uuidString, kind: .bookmark, title: bookmark.title,
                              detail: OmniboxPresentation.displayValue(bookmark.url), input: bookmark.url,
                              score: (quality >= 20 ? 400 : 200) + quality)
        }
    }
}

@MainActor @Observable
final class SuggestionEngine {
    private(set) var results: [Suggestion] = []
    var selectedID: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let remote: any RemoteSuggestionProvider
    @ObservationIgnored var changed: (() -> Void)?
    init(remote: any RemoteSuggestionProvider = BraveSuggestionProvider()) { self.remote = remote }
    func cancelPending() { task?.cancel(); task = nil; generation = UUID() }
    func stop() { cancelPending(); results = []; selectedID = nil; changed?() }
    func update(_ input: String, bookmarks: BookmarkSuggestionProvider?, engine: SearchEngine, allowRemote: Bool) {
        task?.cancel(); task = nil; generation = UUID(); selectedID = nil
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 2048 else { stop(); return }
        let localQuery = query.lowercased()
        var seen = Set<String>()
        let local = ((bookmarks?.suggestions(for: localQuery) ?? []) + CommonSiteSuggestionProvider().suggestions(for: localQuery))
            .sorted { $0.score == $1.score ? $0.title < $1.title : $0.score > $1.score }
            .filter { seen.insert(Self.destinationKey($0.input)).inserted }
        let direct = Suggestion(id: "direct", kind: .directSearch, title: "Search \(engine.displayName) for “\(query)”", detail: "", input: query, score: 0)
        results = Array(local.prefix(3)) + [direct]; changed?()
        guard allowRemote, Self.canSendRemotely(query) else { return }
        let token = generation
        task = Task { [weak self, remote] in
            do {
                try await Task.sleep(for: .milliseconds(160))
                let strings = try await remote.suggestions(for: query)
                guard let self, !Task.isCancelled, self.generation == token else { return }
                let localResults = Array(local.prefix(3))
                var queries = Set([Self.queryKey(query)] + localResults.flatMap { [Self.queryKey($0.title), Self.queryKey($0.detail)] })
                let remoteResults = strings.filter { queries.insert(Self.queryKey($0)).inserted }.prefix(5 - localResults.count).enumerated().map { index, value in
                    Suggestion(id: "remote:" + value, kind: .remoteSearch, title: value, detail: "Search suggestion", input: value, score: 50 - index)
                }
                self.results = localResults + remoteResults + [direct]
                if let id = self.selectedID, !self.results.contains(where: { $0.id == id }) { self.selectedID = nil }
                self.changed?()
            } catch { /* Autocomplete remains local when Brave is unavailable. */ }
        }
    }
    static func queryKey(_ value: String) -> String {
        value.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    static func destinationKey(_ value: String) -> String {
        guard let url = URLComponents(string: value), let host = url.host?.lowercased() else { return queryKey(value) }
        let domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let port = url.port.map { [80, 443].contains($0) ? "" : ":\($0)" } ?? ""
        let path = url.percentEncodedPath == "/" ? "" : url.percentEncodedPath
        return domain + port + path + (url.percentEncodedQuery.map { "?" + $0 } ?? "") + (url.percentEncodedFragment.map { "#" + $0 } ?? "")
    }
    static func canSendRemotely(_ query: String) -> Bool {
        // Avoid sending addresses, credentials, local paths or internal URLs as search prefixes.
        query.count >= 2 && query.count <= 256 && !query.contains(":") && !query.contains("/") && !query.contains("@")
    }
    func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        let current = selectedID.flatMap { id in results.firstIndex { $0.id == id } }
        let next = current.map { ($0 + delta + results.count) % results.count } ?? (delta > 0 ? 0 : results.count - 1)
        selectedID = results[next].id
    }
    var selected: Suggestion? { results.first { $0.id == selectedID } }
}
