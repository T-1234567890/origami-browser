import Foundation

/// A cookie-free, ephemeral request with bounded, bulk data delivery on a serial delegate queue.
final class ReaderImageLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let maximumBytes = 20 * 1024 * 1024
    private var data = Data()
    private var continuation: CheckedContinuation<Data?, Never>?

    static func request(url: URL, pageURL: URL?, userAgent: String?) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("image/avif,image/webp,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        // Send only the origin, never a private query, fragment or embedded credentials.
        if let pageURL, var origin = URLComponents(url: pageURL, resolvingAgainstBaseURL: false),
           ["http", "https"].contains(origin.scheme ?? ""),
           !(origin.scheme == "https" && url.scheme == "http") {
            origin.user = nil; origin.password = nil; origin.query = nil; origin.fragment = nil; origin.path = "/"
            request.setValue(origin.url?.absoluteString, forHTTPHeaderField: "Referer")
        }
        return request
    }

    static func load(url: URL, pageURL: URL?, userAgent: String?,
                     configuration: URLSessionConfiguration = .ephemeral) async -> Data? {
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        let loader = ReaderImageLoader()
        let session = URLSession(configuration: configuration, delegate: loader, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                loader.continuation = continuation
                if Task.isCancelled { loader.finish(nil); return }
                session.dataTask(with: request(url: url, pageURL: pageURL, userAgent: userAgent)).resume()
            }
        } onCancel: { session.invalidateAndCancel() }
    }

    private func finish(_ result: Data?) {
        let completion = continuation
        continuation = nil
        completion?.resume(returning: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              response.expectedContentLength <= Self.maximumBytes else {
            completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard chunk.count <= Self.maximumBytes - data.count else {
            dataTask.cancel(); finish(nil); return
        }
        data.append(chunk)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error == nil ? data : nil)
    }
}
