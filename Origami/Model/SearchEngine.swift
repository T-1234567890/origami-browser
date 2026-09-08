import Foundation

enum SearchEngine: String, Codable, CaseIterable, Identifiable {
    case google, bing, duckDuckGo, brave
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .google: "Google"
        case .bing: "Bing"
        case .duckDuckGo: "DuckDuckGo"
        case .brave: "Brave Search"
        }
    }
    var searchURLTemplate: String {
        switch self {
        case .google: "https://www.google.com/search?q={searchTerms}"
        case .bing: "https://www.bing.com/search?q={searchTerms}"
        case .duckDuckGo: "https://duckduckgo.com/?q={searchTerms}"
        case .brave: "https://search.brave.com/search?q={searchTerms}"
        }
    }
    func searchURL(for query: String) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return URL(string: searchURLTemplate.replacingOccurrences(of: "{searchTerms}", with: encoded))!
    }
}

enum OmniboxRouter {
    static func destination(for input: String, engine: SearchEngine) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), InternalRoute.page(for: url) != nil { return url }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme), url.host?.isEmpty == false { return url }
        if !text.contains(where: \.isWhitespace), !text.contains("@"), !text.contains("://"),
           let url = URL(string: "https://" + text), let host = url.host,
           host == "localhost" || host.contains(".") || host.contains(":") {
            return url
        }
        return engine.searchURL(for: text)
    }
}
