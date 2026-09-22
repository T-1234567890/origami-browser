import Foundation

/// Fetch only resources referenced by the saved document. Never copy browser cookies or auth headers.
final class PageExportResourceLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Resource: Sendable { let data: Data; let mime: String?; let encoding: String? }
    private var data = Data()
    private var response: URLResponse?
    private var completion: CheckedContinuation<Resource?, Never>?
    private static let limit = 8 * 1024 * 1024

    static func load(_ url: URL) async -> Resource? {
        guard ReaderMedia.safeURL(url.absoluteString) != nil else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 4
        let loader = PageExportResourceLoader()
        let session = URLSession(configuration: configuration, delegate: loader, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                loader.completion = continuation
                if Task.isCancelled { loader.finish(nil); return }
                session.dataTask(with: url).resume()
            }
        } onCancel: { session.invalidateAndCancel() }
    }
    private func finish(_ result: Resource?) {
        let callback = completion; completion = nil; callback?.resume(returning: result)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.flatMap { ReaderMedia.safeURL($0.absoluteString) } == nil ? nil : request)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.expectedContentLength <= Self.limit else { completionHandler(.cancel); return }
        self.response = response
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard data.count + chunk.count <= Self.limit else { dataTask.cancel(); return }
        data.append(chunk)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard error == nil, let response else { finish(nil); return }
        finish(Resource(data: data, mime: response.mimeType, encoding: response.textEncodingName))
    }
}
