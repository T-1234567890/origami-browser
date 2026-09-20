import Foundation
import WebKit
import PDFKit

// The preference controls presentation only, never AI or provider routing.
enum PeekMode: String, CaseIterable, Identifiable {
    case off, onDemand, automatic
    var id: Self { self }
    var title: String { switch self { case .off: L10n.string("Off"); case .onDemand: L10n.string("On Demand"); case .automatic: L10n.string("Automatic") } }
    var initialLayer: PeekLayer { self == .automatic ? .structured : .normal }
}
enum PeekLayer: Int { case normal, structured
    func moved(horizontal: CGFloat, vertical: CGFloat) -> Self {
        guard abs(horizontal) > 36, abs(horizontal) > abs(vertical) * 1.4 else { return self }
        if self == .normal && horizontal < 0 { return .structured }
        if self == .structured && horizontal > 0 { return .normal }
        return self
    }
}

struct PeekPreview: Equatable {
    var title: String
    var source: String
    var overview = ""
    var author = ""
    var published = ""
    var category = ""
    var categoryTitle: String {
        guard let first = category.first else { return "" }
        return String(first).uppercased() + category.dropFirst()
    }
    var categorySymbol: String {
        switch category.lowercased() {
        case "article", "newsarticle", "blogposting": "doc.text"
        case "website", "webpage": "globe"
        case "book": "book.closed"
        case "product": "shippingbox"
        default: "tag"
        }
    }
    var headings: [String] = []
    var minutes: Int?
    var imageURL: URL?
    var fileType: String?
    var fileSize: Int64?
    var pageCount: Int?
    var hasDetails: Bool {
        !overview.isEmpty || !author.isEmpty || formattedDate != nil || !headings.isEmpty ||
        minutes != nil || fileType != nil || imageURL != nil || (!category.isEmpty && category != "website" && category != "WebPage")
    }
    var formattedDate: String? {
        Self.formattedDate(published, locale: L10n.locale)
    }
    static func formattedDate(_ text: String, locale: Locale = .current) -> String? {
        guard !text.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = iso.date(from: text)
        if date == nil { iso.formatOptions = [.withInternetDateTime]; date = iso.date(from: text) }
        if date == nil {
            let plain = DateFormatter(); plain.locale = Locale(identifier: "en_US_POSIX")
            plain.calendar = Calendar(identifier: .gregorian); plain.timeZone = TimeZone(secondsFromGMT: 0)
            plain.dateFormat = "yyyy-MM-dd"; plain.isLenient = false
            if text.count == 10 { date = plain.date(from: text) }
        }
        guard let date else { return nil }
        let display = DateFormatter(); display.locale = locale; display.dateStyle = .medium; display.timeStyle = .none
        // Publication dates are calendar metadata; avoid shifting them into yesterday locally.
        display.timeZone = TimeZone(secondsFromGMT: 0)
        return display.string(from: date)
    }
    static let documentExtensions = Set(["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "rtf", "odt", "ods", "odp"])
    static func documentType(_ url: URL) -> String? {
        documentExtensions.contains(url.pathExtension.lowercased()) ? url.pathExtension.uppercased() : nil
    }
    static func documentType(mime: String?) -> String? {
        switch mime?.lowercased() {
        case "application/pdf": "PDF"
        case "application/msword", "application/vnd.openxmlformats-officedocument.wordprocessingml.document": L10n.string("Word document")
        case "application/vnd.ms-excel", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": L10n.string("Spreadsheet")
        case "application/vnd.ms-powerpoint", "application/vnd.openxmlformats-officedocument.presentationml.presentation": L10n.string("Presentation")
        case "application/vnd.apple.pages": L10n.string("Pages document")
        case "application/vnd.apple.numbers": L10n.string("Numbers spreadsheet")
        case "application/vnd.apple.keynote": L10n.string("Keynote presentation")
        default: nil
        }
    }
    init(url: URL) {
        title = Self.documentType(url) != nil ? url.lastPathComponent : (url.host ?? "Preview")
        source = url.host ?? ""; fileType = Self.documentType(url)
    }
    // Use the actual navigation destination, never the referring page or its redirect URL.
    static func destinationURL(loaded: URL?, requested: URL) -> URL {
        loaded.flatMap { ReaderMedia.safeURL($0.absoluteString) } ?? requested
    }
    static func imageSize(_ size: CGSize) -> CGSize {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return .zero }
        let scale = min(1, 96 / size.width, 48 / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
    mutating func apply(_ value: [String: Any]) {
        func text(_ key: String, limit: Int = 240) -> String {
            String((value[key] as? String ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(limit))
        }
        let name = text("title"); if !name.isEmpty { title = name }
        overview = text("overview", limit: 420); author = text("author", limit: 100)
        published = text("published", limit: 60); category = text("category", limit: 60)
        headings = Array((value["headings"] as? [String] ?? []).prefix(6)).map { String($0.prefix(100)) }.filter { !$0.isEmpty }
        if let words = value["words"] as? Int, words >= 100 { minutes = min(999, max(1, Int(ceil(Double(words) / 220)))) }
        imageURL = ReaderMedia.safeURL(text("image", limit: 4096))
    }
}

enum PeekExtraction {
    // Isolated content world. Website strings become native Text, never HTML or instructions.
    static let script = #"""
    const clean = (value, limit=420) => typeof value === 'string' ? value.replace(/\s+/g,' ').trim().slice(0,limit) : '';
    const meta = (...names) => names.map(name => document.querySelector(`meta[property="${name}"],meta[name="${name}"]`)?.content).find(Boolean) || '';
    let structured = [];
    for (const node of [...document.querySelectorAll('script[type="application/ld+json"]')].slice(0,8)) {
      if (node.textContent.length > 100000) continue;
      try { const data=JSON.parse(node.textContent); structured.push(...(Array.isArray(data)?data:[data])); } catch (_) {}
    }
    structured = structured.flatMap(item => item && Array.isArray(item['@graph']) ? item['@graph'].slice(0,30) : [item]);
    const article = structured.find(item => item && /Article|BlogPosting|NewsArticle|WebPage/.test(String(item['@type']))) || {};
    const author = Array.isArray(article.author) ? article.author[0] : article.author;
    const main = document.querySelector('article,main,[role="main"]');
    const paragraphs = main ? [...main.querySelectorAll('p')].slice(0,40).map(p=>clean(p.textContent)).filter(p=>p.length>60) : [];
    const text = main ? main.textContent.slice(0,100000) : '';
    const imageValue = meta('og:image','twitter:image') || (Array.isArray(article.image)?article.image[0]:article.image);
    let image = typeof imageValue === 'string' ? imageValue : imageValue?.url;
    try { image = image ? new URL(image, document.baseURI).href : ''; } catch (_) { image = ''; }
    return {title:clean(meta('og:title','twitter:title') || article.headline || document.title,240),
      overview:clean(meta('description','og:description','twitter:description') || article.description || paragraphs[0]),
      author:clean(meta('author') || (typeof author === 'string' ? author : author?.name),100),
      published:clean(meta('article:published_time') || article.datePublished || document.querySelector('time[datetime]')?.dateTime,60),
      category:clean(meta('article:section','og:type') || article.articleSection || article['@type'],60),
      headings:[...(main || document).querySelectorAll('h2,h3')].slice(0,6).map(h=>clean(h.textContent,100)).filter(Boolean),
      words:text.trim() ? text.trim().split(/\s+/).length : 0, image:clean(image,4096)};
    """#
    @MainActor static func page(_ page: TabPage, url: URL) async -> PeekPreview {
        var result = PeekPreview(url: PeekPreview.destinationURL(loaded: page.webView.url, requested: url))
        if let value = try? await page.webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: Any] { result.apply(value) }
        return result
    }
    static func document(_ url: URL, type: String? = nil) async -> PeekPreview {
        var result = PeekPreview(url: url)
        guard ReaderMedia.safeURL(url.absoluteString) != nil else { return result }
        result.fileType = type ?? result.fileType
        // Office/iWork previews use response metadata only; no archive expansion or execution.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, timeoutInterval: 8); request.httpMethod = "HEAD"
        if let (_, response) = try? await session.data(for: request),
           let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), response.expectedContentLength > 0 {
            result.fileSize = response.expectedContentLength
        }
        guard result.fileType == "PDF", result.fileSize == nil || result.fileSize! <= Int64(PeekDocumentLoader.maximumBytes),
              !Task.isCancelled, let data = await PeekDocumentLoader.load(url: url, pageURL: nil, userAgent: nil),
              !Task.isCancelled else { return result }
        return pdf(data, fallback: result)
    }
    static func pdf(_ data: Data, fallback: PeekPreview) -> PeekPreview {
        var result = fallback
        guard data.count <= PeekDocumentLoader.maximumBytes, let pdf = PDFDocument(data: data) else { return result }
        result.fileSize = Int64(data.count); result.pageCount = pdf.pageCount
        if let title = pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, !title.isEmpty { result.title = String(title.prefix(240)) }
        result.author = String((pdf.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String ?? "").prefix(100))
        result.overview = String((pdf.page(at: 0)?.string ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(420))
        return result
    }
}
