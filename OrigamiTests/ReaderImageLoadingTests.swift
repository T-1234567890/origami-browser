import Foundation
import Testing
@testable import Origami

struct ReaderImageLoadingTests {
    @Test func embeddedVideoShellIsSandboxedAndReferrerIsSanitized() {
        let html = ReaderEmbeddedVideo.html(url: URL(string: "https://video.example.invalid/embed/123?start=0&title=1")!)
        #expect(html.contains("<iframe"))
        #expect(html.contains("start=0&amp;title=1"))
        #expect(html.contains("sandbox=\"allow-scripts allow-same-origin allow-presentation\""))
        #expect(!html.contains("allow-top-navigation"))
        #expect(!html.contains("allow-popups"))
        #expect(!html.contains("autoplay"))
        #expect(ReaderEmbeddedVideo.baseURL(URL(string: "https://user:password@example.invalid/article?private=1#section"))?.absoluteString == "https://example.invalid/")
        #expect(ReaderEmbeddedVideo.baseURL(URL(string: "file:///private/article")) == nil)
    }

    @Test func requestUsesBrowserHeadersWithoutSensitiveReferrerComponents() {
        let request = ReaderImageLoader.request(url: URL(string: "https://images.example.invalid/photo")!,
            pageURL: URL(string: "https://user:secret@example.invalid/article?token=private#fragment"), userAgent: "Fixture Browser")
        #expect(request.value(forHTTPHeaderField: "Referer") == "https://example.invalid/")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Fixture Browser")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test(.timeLimit(.minutes(1))) func bulkImageResponseAndFailuresUseLocalFixtures() async {
        for (path, count) in [("image", 4 * 1024 * 1024), ("denied", 0), ("large", 0)] {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [ReaderImageProtocol.self]
            let data = await ReaderImageLoader.load(url: URL(string: "https://example.invalid/" + path)!,
                pageURL: nil, userAgent: nil, configuration: config)
            #expect(data?.count ?? 0 == count)
            #expect(config.httpCookieStorage == nil)
            #expect(config.timeoutIntervalForResource == 20)
        }
    }
}

private final class ReaderImageProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.lastPathComponent
        let length = path == "large" ? ReaderImageLoader.maximumBytes + 1 : 4 * 1024 * 1024
        let response = HTTPURLResponse(url: request.url!, statusCode: path == "denied" ? 403 : 200,
                                       httpVersion: nil, headerFields: ["Content-Length": String(length), "Content-Type": "image/png"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if path == "image" {
            let chunk = Data(repeating: 42, count: 64 * 1024)
            for _ in 0..<64 { client?.urlProtocol(self, didLoad: chunk) }
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
