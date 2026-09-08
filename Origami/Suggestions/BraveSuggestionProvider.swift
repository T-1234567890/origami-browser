import Foundation

protocol RemoteSuggestionProvider: Sendable {
    func suggestions(for query: String) async throws -> [String]
}

struct BraveSuggestionProvider: RemoteSuggestionProvider {
    func suggestions(for query: String) async throws -> [String] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var components = URLComponents(string: "https://search.brave.com/api/suggest")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 65_536 else { return [] }
            data.append(byte)
        }
        return Self.parse(data)
    }
    static func parse(_ data: Data) -> [String] {
        guard data.count <= 65_536, let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
              array.count >= 2, array[0] is String, let values = array[1] as? [Any] else { return [] }
        var seen = Set<String>()
        return values.compactMap { $0 as? String }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 256 && !$0.contains(where: { $0.isNewline }) && seen.insert($0.lowercased()).inserted }
            .prefix(8).map { $0 }
    }
}
