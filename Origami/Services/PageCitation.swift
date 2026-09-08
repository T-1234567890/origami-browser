import Foundation
import WebKit

struct PageCitation: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var title: String
    var author: String = ""
    var publisher: String = ""
    var published: String = ""
    var updated: String = ""
    var url: String
    var doi: String = ""
    var quotation: String = ""
    var accessed: String = Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash))
    static let formats = ["APA", "MLA", "Chicago"]
    static let exportFormats = formats + ["BibTeX", "RIS", "Markdown"]
    static func formatLabel(_ format: String) -> String { ["APA": "APA 7th", "MLA": "MLA 9th", "Chicago": "Chicago 18th · Author–date"][format] ?? format }
    func formatted(_ format: String) -> String {
        if Self.formats.contains(format) { return CitationProcessor.render(self, style: format) ?? "Citation formatting unavailable. Please try again." }
        let location = doi.isEmpty ? url : "https://doi.org/" + doi.replacingOccurrences(of: "https://doi.org/", with: "")
        let quote = quotation.isEmpty ? "" : "\n\n“\(quotation)”"
        switch format {
        case "BibTeX":
            func safe(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\textbackslash{}").replacingOccurrences(of: "{", with: "\\{").replacingOccurrences(of: "}", with: "\\}").replacingOccurrences(of: "\n", with: " ") }
            var fields = [("title",title),("author",author),("publisher",publisher),("date",published),("url",url),("doi",doi),("urldate",accessed),("note",quotation)]
            fields.removeAll { $0.1.isEmpty }
            return "@misc{origami\(id.replacingOccurrences(of: "-", with: "")),\n" + fields.map { "  \($0.0) = {\(safe($0.1))}" }.joined(separator: ",\n") + "\n}"
        case "RIS":
            let fields = [("TI",title),("AU",author),("PB",publisher),("PY",published),("UR",url),("DO",doi),("Y2",accessed),("N1",quotation)]
            return "TY  - ELEC\n" + fields.filter { !$0.1.isEmpty }.map { "\($0.0)  - \($0.1.replacingOccurrences(of: "\n", with: " "))" }.joined(separator: "\n") + "\nER  - \n"
        case "Markdown": return "[\(title)](\(location))" + (author.isEmpty ? "" : " — \(author)") + (published.isEmpty ? "" : ", \(published)") + ". Accessed \(accessed)." + (quotation.isEmpty ? "" : "\n\n> " + quotation.replacingOccurrences(of: "\n", with: "\n> "))
        default: return [title,author,publisher,published,url,doi.isEmpty ? "" : "DOI: " + doi,"Accessed: " + accessed].filter { !$0.isEmpty }.joined(separator: ". ") + quote
        }
    }
    @MainActor static func extract(_ page: TabPage, selection: Bool) async throws -> PageCitation {
        guard page.nativePage == nil, let url = page.currentURL, ["http", "https"].contains(url.scheme) else { throw RepositoryError.invalidInput }
        let script = """
        const meta = (...keys) => {
          for (const key of keys) { const e=document.querySelector('meta[name="'+key+'"],meta[property="'+key+'"]'); if(e?.content) return e.content; } return '';
        };
        let article = {};
        for (const node of document.querySelectorAll('script[type="application/ld+json"]')) {
          if (node.textContent.length > 200000) continue;
          try {
            const root = JSON.parse(node.textContent);
            const entries = Array.isArray(root) ? root : [root, ...(root['@graph'] || [])];
            const found = entries.find(x => /Article|BlogPosting|ScholarlyArticle/.test(String(x['@type'])));
            if (found) { article = found; break; }
          } catch (_) {}
        }
        const names = x => typeof x === 'string' ? x : Array.isArray(x) ? x.map(names).filter(Boolean).join('; ') : x?.name || '';
        const canonical=document.querySelector('link[rel="canonical"]')?.href || location.href;
        return { title: meta('citation_title','og:title') || article.headline || document.title,
          author: Array.from(document.querySelectorAll('meta[name=\"citation_author\"]')).map(x=>x.content).filter(Boolean).join('; ') || meta('author','article:author') || names(article.author), publisher: meta('citation_publisher','citation_journal_title','og:site_name') || names(article.publisher),
          published: meta('citation_publication_date','article:published_time','date') || article.datePublished || document.querySelector('article time[datetime]')?.dateTime || '', updated: meta('article:modified_time') || article.dateModified || '',
          doi: meta('citation_doi','DC.Identifier.DOI'), url: /^https?:/.test(canonical) ? canonical : location.href,
          quotation: window.getSelection()?.toString().slice(0,50000) || '' };
        """
        let result = try await page.webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .world(name: "Origami.Citation")) as? [String:String] ?? [:]
        if selection && (result["quotation"] ?? "").isEmpty { throw CitationError.noSelection }
        return PageCitation(title: result["title"] ?? page.pageTitle ?? url.host ?? "Untitled", author: result["author"] ?? "", publisher: result["publisher"] ?? "", published: result["published"] ?? "", updated: result["updated"] ?? "", url: result["url"] ?? url.absoluteString, doi: result["doi"] ?? "", quotation: selection ? result["quotation"] ?? "" : "")
    }
}
enum CitationError: LocalizedError {
    case noSelection
    var errorDescription: String? { "Select text on the page before choosing Cite Selection." }
}
