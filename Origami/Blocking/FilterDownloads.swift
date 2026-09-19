import Foundation

struct FilterSnapshot: Codable, Sendable {
    let originals: [String]
    let rules: [BlockingRule]
    let updated: Date
    let skipped: Int
    let attribution: String
}
enum FilterDownloads {
    static let sources = [URL(string: "https://easylist.to/easylist/easylist.txt")!, URL(string: "https://easylist.to/easylist/easyprivacy.txt")!]
    static let notice = """
    EasyList and EasyPrivacy — The EasyList authors (https://easylist.to/).
    Sources: https://easylist.to/easylist/easylist.txt and https://easylist.to/easylist/easyprivacy.txt
    License: Creative Commons Attribution-ShareAlike 3.0 Unported or later.
    https://creativecommons.org/licenses/by-sa/3.0/ — https://easylist.to/pages/licence.html
    The originals are downloaded third-party data, not MPL-2.0 Origami source.
    The rules are a locally converted, incomplete WebKit derivative made by Origami;
    they remain under CC BY-SA 3.0-or-later. No endorsement by the authors is implied.
    """
    enum Failure: Error { case invalidResponse, oversized }
    typealias Progress = @MainActor @Sendable (Double?) -> Void
    static func fetch(_ url: URL, progress: @escaping Progress = { _ in }) async throws -> String {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration, delegate: OfficialSourceOnly(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url == url, response.expectedContentLength <= 12_000_000 else { throw Failure.invalidResponse }
        let total = [nil, "identity"].contains(response.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()) && response.expectedContentLength > 0 ? response.expectedContentLength : nil
        await progress(total == nil ? nil : 0)
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 12_000_000 else { throw Failure.oversized }
            data.append(byte)
            if data.count.isMultiple(of: 65_536) {
                await progress(total.map { min(Double(data.count) / Double($0), 1) })
            }
        }
        guard let text = String(data: data, encoding: .utf8), text.hasPrefix("[Adblock") else { throw Failure.invalidResponse }
        await progress(1)
        return text
    }
    private final class OfficialSourceOnly: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil) // Never send subscription requests to an unconfigured host/path.
        }
    }
}
