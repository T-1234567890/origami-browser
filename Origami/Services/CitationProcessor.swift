import Foundation
import JavaScriptCore

/// CSL formatting runs offline in JavaScriptCore, with no native objects or web bridge.
enum CitationProcessor {
    static func render(_ citation: PageCitation, style: String) -> String? {
        var citation = citation
        citation.title = String(citation.title.prefix(4096))
        citation.author = String(citation.author.prefix(4096))
        citation.publisher = String(citation.publisher.prefix(4096))
        citation.published = String(citation.published.prefix(100))
        citation.url = String(citation.url.prefix(8192))
        citation.doi = String(citation.doi.prefix(512))
        citation.quotation = String(citation.quotation.prefix(50000))
        let names = ["APA": "apa", "MLA": "modern-language-association", "Chicago": "chicago-author-date"]
        guard let name = names[style], let context = JSContext(),
              let processor = resource("citeproc", "js"), let xml = resource(name, "csl"),
              let locale = resource("locales-en-US", "xml") else { return nil }
        var item: [String: Any] = ["id": citation.id, "type": "webpage", "title": citation.title, "URL": citation.url]
        if !citation.author.isEmpty {
            item["author"] = citation.author.components(separatedBy: ";").map { name -> [String: String] in
                let parts = name.trimmingCharacters(in: .whitespaces).components(separatedBy: ",")
                // Explicit family, given syntax avoids guessing organizations or multipart surnames.
                return parts.count == 2 ? ["family": parts[0].trimmingCharacters(in: .whitespaces), "given": parts[1].trimmingCharacters(in: .whitespaces)] : ["literal": name.trimmingCharacters(in: .whitespaces)]
            }
        }
        if !citation.publisher.isEmpty { item["container-title"] = citation.publisher }
        if !citation.doi.isEmpty { item["DOI"] = citation.doi.replacingOccurrences(of: "https://doi.org/", with: "") }
        for (key, value) in [("issued", citation.published), ("accessed", citation.accessed)] where !value.isEmpty {
            let date = String(value.prefix(10)).split(separator: "-").compactMap { Int($0) }
            item[key] = !date.isEmpty && date[0] > 999 ? ["date-parts": [date]] : ["literal": value]
        }
        context.evaluateScript(processor)
        context.setObject(item, forKeyedSubscript: "citationItem" as NSString)
        context.setObject(xml, forKeyedSubscript: "citationStyle" as NSString)
        context.setObject(locale, forKeyedSubscript: "citationLocale" as NSString)
        let value = context.evaluateScript("""
        (function() {
          var engine = new CSL.Engine({retrieveLocale:function(){return citationLocale;}, retrieveItem:function(){return citationItem;}}, citationStyle, 'en-US');
          engine.setOutputFormat('text');
          engine.updateItems([citationItem.id]);
          return engine.makeBibliography()[1].join('').trim();
        })()
        """)
        guard context.exception == nil, let text = value?.toString(), !text.isEmpty, text != "undefined" else { return nil }
        return text + (citation.quotation.isEmpty ? "" : "\n\n“\(citation.quotation)”")
    }
    private static func resource(_ name: String, _ ext: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

/// Serialize CPU-heavy CSL work away from SwiftUI rendering and the AppKit main thread.
actor CitationFormattingWorker {
    static let shared = CitationFormattingWorker()
    func format(_ citation: PageCitation, style: String) -> String {
        citation.formatted(style)
    }
}
