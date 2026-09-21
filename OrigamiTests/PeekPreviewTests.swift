import Testing
import WebKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers
@testable import Origami

@MainActor struct PeekPreviewTests {
    @Test func contentTypesHaveCapitalizedLabelsAndIcons() {
        var preview = PeekPreview(url: URL(string: "https://example.invalid")!)
        preview.category = "article"
        #expect(preview.categoryTitle == "Article")
        #expect(preview.categorySymbol == "doc.text")
        preview.category = "technology"
        #expect(preview.categoryTitle == "Technology")
        #expect(preview.categorySymbol == "tag")
        preview.category = ""
        #expect(preview.categoryTitle.isEmpty)
    }
    @Test func datesUseReadableLocalizedFormatting() {
        let locale = Locale(identifier: "en_US")
        for input in ["2026-09-19T23:30:00.000Z", "2026-09-19T23:30:00Z", "2026-09-19"] {
            #expect(PeekPreview.formattedDate(input, locale: locale) == "Sep 19, 2026")
        }
        #expect(PeekPreview.formattedDate("not a date", locale: locale) == nil)
        #expect(PeekPreview.formattedDate("", locale: locale) == nil)
    }
    @Test func emptyDetailsRequireActualMetadata() {
        var preview = PeekPreview(url: URL(string: "https://example.invalid")!)
        preview.apply(["title": "Page title", "category": "website", "published": "invalid"])
        #expect(!preview.hasDetails)
        preview.headings = ["Topic"]
        #expect(preview.hasDetails)
        preview.headings = []; preview.author = "Author"
        #expect(preview.hasDetails)
    }
    @Test func modesPersistAndOffPreventsPreview() {
        let name = "Origami.PeekFixture." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = BrowserPreferences(defaults: defaults)
        #expect(preferences.peekMode == .onDemand)
        preferences.peekMode = .automatic
        #expect(BrowserPreferences(defaults: defaults).peekMode == .automatic)
        #expect(PeekMode.automatic.initialLayer == .structured)
        #expect(PeekMode.onDemand.initialLayer == .normal)
        let store = BrowserStore(preferences: preferences)
        defer { store.dismissPeek(); store.pages.values.forEach { $0.dispose() } }
        store.setPeekMode(.off)
        store.openPeek(URL(string: "https://example.invalid/article")!)
        #expect(store.peekPage == nil)
        store.setPeekMode(.onDemand)
        store.openPeek(URL(string: "https://example.invalid/report.pdf")!)
        #expect(store.peekPage != nil)
        #expect(store.peekPage?.webView.url == nil) // Document preview does not start WebKit downloads.
        store.setPeekMode(.off)
        #expect(store.peekPage == nil)
    }
    @Test func horizontalOnlyAndBoundaries() {
        #expect(PeekLayer.normal.moved(horizontal: -80, vertical: 4) == .structured)
        #expect(PeekLayer.structured.moved(horizontal: 80, vertical: 4) == .normal)
        #expect(PeekLayer.normal.moved(horizontal: 80, vertical: 4) == .normal)
        #expect(PeekLayer.normal.moved(horizontal: -40, vertical: 90) == .normal)
        #expect(PeekLayer.normal.moved(horizontal: -15, vertical: 0) == .normal)
    }
    @Test func videoPlaybackLinksNeverShowPeek() {
        for value in ["https://www.youtube.com/watch?v=fixture", "https://youtu.be/fixture",
                      "https://youtube.com/shorts/fixture", "https://player.vimeo.com/video/123",
                      "https://example.invalid/movie.m4v", "https://example.invalid/live.m3u8",
                      "https://www.google.com/url?q=https%3A%2F%2Fyoutube.com%2Fwatch%3Fv%3Dfixture"] {
            #expect(!LinkPeekObserver.canPreview(URL(string: value)!))
        }
        #expect(LinkPeekObserver.canPreview(URL(string: "https://example.invalid/article-about-video")!))
        #expect(LinkPeekObserver.canPreview(URL(string: "https://youtube.com/about")!))
    }
    @Test func documentRecognitionAndUnsafeLinks() {
        #expect(PeekPreview.documentType(mime: "application/pdf") == "PDF")
        #expect(PeekPreview.documentType(mime: "text/html") == nil)
        for ext in ["pdf", "docx", "pages", "xlsx", "pptx", "key", "png", "jpg", "gif", "webp", "heic", "tiff", "zip", "txt"] {
            #expect(LinkPeekObserver.canPreview(URL(string: "https://example.com/file.\(ext)")!))
        }
        for text in ["file:///tmp/test.pdf", "javascript:alert(1)", "https://user:password@example.com/file.pdf"] {
            #expect(!LinkPeekObserver.canPreview(URL(string: text)!))
        }
    }
    @Test func sourceUsesLoadedDestinationAfterRedirect() {
        let requested = URL(string: "https://search.example/url?q=destination")!
        let destination = URL(string: "https://en.wikipedia.org/wiki/Apple_Inc.")!
        let preview = PeekPreview(url: PeekPreview.destinationURL(loaded: destination, requested: requested))
        #expect(preview.source == "en.wikipedia.org")
        #expect(PeekPreview.destinationURL(loaded: nil, requested: requested) == requested)
        #expect(PeekPreview.destinationURL(loaded: URL(string: "about:blank"), requested: requested) == requested)
    }
    @Test func detailImagesRemainCompactWithoutCroppingOrUpscaling() {
        #expect(PeekPreview.imageSize(CGSize(width: 800, height: 400)) == CGSize(width: 96, height: 48))
        #expect(PeekPreview.imageSize(CGSize(width: 400, height: 800)) == CGSize(width: 24, height: 48))
        #expect(PeekPreview.imageSize(CGSize(width: 500, height: 500)) == CGSize(width: 48, height: 48))
        #expect(PeekPreview.imageSize(CGSize(width: 16, height: 16)) == CGSize(width: 16, height: 16))
        #expect(PeekPreview.imageSize(.zero) == .zero)
    }
    @Test func metadataBoundsAndUnsafeImages() {
        var preview = PeekPreview(url: URL(string: "https://example.com/article")!)
        preview.apply(["title": String(repeating: "x", count: 1000), "image": "file:///tmp/private", "headings": Array(repeating: "Heading", count: 20), "words": 441])
        #expect(preview.title.count == 240 && preview.headings.count == 6)
        #expect(preview.imageURL == nil && preview.minutes == 3)
    }
    @Test func extractsOpenGraphSchemaAndHeadingsWithoutAI() async throws {
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)
        defer { web.stopLoading() }
        web.loadHTMLString("""
        <title>Fallback title</title><meta property="og:title" content="Article title">
        <meta property="og:image" content="/hero.png">
        <script type="application/ld+json">{"@type":"Article","author":{"name":"Fixture Author"},"datePublished":"2026-01-02","description":"A deterministic overview."}</script>
        <article><h2>First section</h2><p>\(String(repeating: "word ", count: 250))</p><h3>Second section</h3></article>
        """, baseURL: URL(string: "https://example.invalid"))
        for _ in 0..<100 {
            if web.title == "Fallback title" && !web.isLoading { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        let value = try #require(try await web.callAsyncJavaScript(PeekExtraction.script, arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: Any])
        var preview = PeekPreview(url: URL(string: "https://example.invalid/article")!); preview.apply(value)
        #expect(preview.title == "Article title")
        #expect(preview.author == "Fixture Author" && preview.published == "2026-01-02")
        #expect(preview.overview == "A deterministic overview.")
        #expect(preview.headings == ["First section", "Second section"])
        #expect(preview.imageURL?.absoluteString == "https://example.invalid/hero.png")
        #expect(preview.minutes == 2)
    }
    @Test func documentLoaderRejectsOversizeAndUnexpectedContent() async {
        for (path, expected) in [("pdf", 128), ("large", 0), ("html", 0)] {
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [PeekDocumentProtocol.self]
            let data = await PeekDocumentLoader.load(url: URL(string: "https://example.invalid/" + path)!, pageURL: nil, userAgent: nil, configuration: config)
            #expect(data?.count ?? 0 == expected)
            #expect(config.httpCookieStorage == nil && config.urlCache == nil)
        }
    }
    @Test func imagePreviewRetainsAnimatedFramesAndRejectsInvalidData() throws {
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.gif.identifier as CFString, 2, nil))
        for color in [NSColor.red, NSColor.blue] {
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            let image = try #require(context.makeImage())
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        let fallback = PeekPreview(url: URL(string: "https://example.invalid/image.gif")!)
        let preview = PeekExtraction.image(output as Data, fallback: fallback)
        let data = try #require(preview.imageData)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetCount(source) == 2)
        #expect(preview.hasFilePreview && preview.pdfData == nil)
        #expect(NSImage(data: data) != nil)
        #expect(!PeekExtraction.image(Data("not an image".utf8), fallback: fallback).hasFilePreview)
        #expect(!PeekPreview(url: URL(string: "https://example.invalid/report.docx")!).hasFilePreview)
        #expect(PeekPreview.documentType(mime: "image/gif") == "GIF")
    }
    @Test func commonTextPreviewsRenderContentAndRejectBinary() throws {
        func fallback(_ ext: String) -> PeekPreview {
            PeekPreview(url: URL(string: "https://example.invalid/file.\(ext)")!)
        }
        let plain = "Hello, 世界\nSecond line"
        for ext in ["txt", "csv", "json", "yaml", "log", "swift"] {
            #expect(LinkPeekObserver.canPreview(URL(string: "https://example.invalid/file.\(ext)")!))
            #expect(PeekExtraction.text(Data(plain.utf8), fallback: fallback(ext)).textPreview?.string == plain)
        }
        let utf16 = try #require(plain.data(using: .utf16))
        #expect(PeekExtraction.text(utf16, fallback: fallback("txt")).textPreview?.string == plain)
        let markdown = PeekExtraction.text(Data("# Heading\n\nA **bold** word.".utf8), fallback: fallback("md"))
        let formatted = try #require(markdown.textPreview)
        #expect(formatted.string == "Heading\n\nA bold word.")
        let headingFont = try #require(formatted.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(headingFont.pointSize > 12)
        let rich = NSAttributedString(string: "Rich text", attributes: [.font: NSFont.boldSystemFont(ofSize: 16)])
        let rtf = try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        #expect(PeekExtraction.text(rtf, fallback: fallback("rtf")).textPreview?.string == "Rich text")
        #expect(!PeekExtraction.text(Data([0, 1, 2]), fallback: fallback("txt")).hasFilePreview)
        #expect(!PeekExtraction.text(Data(repeating: 65, count: 512 * 1024 + 1), fallback: fallback("txt")).hasFilePreview)
        #expect(!PeekDocumentLoader.supports("text/html"))
        #expect(PeekDocumentLoader.supports("text/markdown"))
        #expect(PeekDocumentLoader.supports("application/rtf"))
    }
    @Test func pdfMetadataUsesActualDocument() throws {
        let document = PDFDocument()
        let image = NSImage(size: NSSize(width: 30, height: 30))
        image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 30, height: 30).fill(); image.unlockFocus()
        document.insert(try #require(PDFPage(image: image)), at: 0)
        document.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Synthetic report", PDFDocumentAttribute.authorAttribute: "Fixture"]
        let data = try #require(document.dataRepresentation())
        let preview = PeekExtraction.pdf(data, fallback: PeekPreview(url: URL(string: "https://example.invalid/report.pdf")!))
        #expect(preview.pageCount == 1 && preview.fileSize == Int64(data.count))
        #expect(preview.title == "Synthetic report" && preview.author == "Fixture")
        let previewData = try #require(preview.pdfData)
        let rendered = try #require(PDFDocument(data: previewData))
        #expect(rendered.pageCount == document.pageCount)
        #expect(rendered.page(at: 0)?.bounds(for: .mediaBox) == document.page(at: 0)?.bounds(for: .mediaBox))
    }
}

private final class PeekDocumentProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.lastPathComponent
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [
            "Content-Type": path == "html" ? "text/html" : "application/pdf",
            "Content-Length": path == "large" ? "9000000" : "128"
        ])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 0, count: 128))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
