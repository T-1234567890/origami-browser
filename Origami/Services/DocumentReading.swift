import Foundation
import WebKit

struct ReaderArticle: Equatable {
    var title: String
    var author: String
    var date: String
    var markdown: String
    var minutes: Int { max(1, markdown.split(whereSeparator: \.isWhitespace).count / 220) }
}
struct ResponseDetails {
    var status: Int
    var headers: [String: String]
    var mime: String
    var seconds: Double?
}

extension TabPage {
    /// Client-rendered articles can arrive after WebKit's navigation completes.
    func scheduleDocumentDiscovery() {
        documentTask?.cancel()
        let generation = documentGeneration
        documentTask = Task { @MainActor [weak self] in
            for delay in [0, 1, 2, 4, 8] {
                if delay > 0 {
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                }
                guard let self, !Task.isCancelled, self.documentGeneration == generation,
                      self.nativePage == nil else { return }
                await self.discoverDocuments()
                if self.article != nil || self.jsonText != nil { return }
            }
        }
    }

    func discoverFeeds() async {
        let generation = documentGeneration
        guard nativePage == nil, !Task.isCancelled else { return }
        if let mime = responseDetails?.mime.lowercased(), mime.contains("rss") || mime.contains("atom"), let url = currentURL {
            discoveredFeeds = [url]; return
        }
        if let urls = try? await webView.callAsyncJavaScript(FeedDiscovery.script, arguments: [:], in: nil, contentWorld: .defaultClient) as? [String],
           generation == documentGeneration, !Task.isCancelled {
            discoveredFeeds = urls.compactMap(URL.init(string:))
        }
    }

    func discoverDocuments() async {
        let generation = documentGeneration
        guard nativePage == nil, !Task.isCancelled else { return }
        if let mime = responseDetails?.mime, mime.contains("rss") || mime.contains("atom"), let url = currentURL {
            discoveredFeeds = [url]; return
        }
        if responseDetails?.mime.contains("json") == true {
            if let raw = try? await webView.evaluateJavaScript("document.body.innerText.length <= 2097152 ? document.body.innerText : null") as? String,
               let data = raw.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) != nil,
               generation == documentGeneration, !Task.isCancelled {
                jsonText = raw
            }
            return
        }
        await discoverFeeds()
        guard let scriptURL = Bundle.main.url(forResource: "Readability", withExtension: "js"),
              let script = try? String(contentsOf: scriptURL, encoding: .utf8) else { return }
        let extract = script + """
        ; return (() => {
          if (document.querySelectorAll('*').length > 50000) return null;
          const host = location.hostname;
          if (/(^|\\.)(google\\.[a-z.]+|bing\\.com|duckduckgo\\.com|search\\.yahoo\\.com)$/.test(host)) return null;
          const declared = document.querySelector('article,[itemtype*=Article],meta[property="og:type"][content="article"]');
          const article = new Readability(document.cloneNode(true), {charThreshold: 500, maxElemsToParse:50000}).parse();
          if (!article) return null;
          const doc = new DOMParser().parseFromString(article.content, 'text/html');
          // Measure cleaned article prose, not the site's menus and related links.
          const paragraphs = Array.from(doc.querySelectorAll('p')).filter(p => p.textContent.trim().length >= 60);
          const prose = paragraphs.reduce((n,p) => n+p.textContent.trim().length,0);
          const linked = Array.from(doc.querySelectorAll('a')).reduce((n,a)=>n+a.textContent.trim().length,0);
          if (paragraphs.length < (declared ? 2 : 3) || prose < (declared ? 500 : 1200) || linked > prose * 0.45) return null;
          const blocks = Array.from(doc.querySelectorAll('h1,h2,h3,h4,p,li,blockquote,pre')).filter(x => !x.parentElement.closest('li,blockquote,pre'));
          const text = blocks.map(x => {
            const inline = node => {
              if (node.nodeType === Node.TEXT_NODE) return node.textContent.replace(/[\\[\\]\\*\\_]/g, '\\\\$&');
              const text = Array.from(node.childNodes).map(inline).join('');
              if (node.tagName === 'A') {
                try { const url = new URL(node.getAttribute('href'), document.baseURI); if (/^https?:$/.test(url.protocol)) return '['+text+']('+url.href.replace(/\\(/g,'%28').replace(/\\)/g,'%29')+')'; } catch (_) {}
              }
              return text;
            };
            const t=inline(x).trim(); if(!t) return '';
            const tag=x.tagName; return (/^H[1-4]$/.test(tag) ? '#'.repeat(Number(tag[1]))+' ' : tag==='LI' ? '- ' : tag==='BLOCKQUOTE' ? '> ' : '')+t;
          }).filter(Boolean).join('\\n\\n');
          return {title:article.title||document.title, author:article.byline||'', date:article.publishedTime||'', markdown:text||article.textContent};
        })()
        """
        if let result = try? await webView.callAsyncJavaScript(extract, arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: String],
           generation == documentGeneration, !Task.isCancelled, let title = result["title"], let text = result["markdown"], text.count >= 500 {
            article = ReaderArticle(title: title, author: (result["author"] ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " "), date: result["date"] ?? "", markdown: text)
            if readerWhenReady { readerVisible = true; readerWhenReady = false }
        }
    }
}

/// Inspect declared feeds and explicit feed links without fetching guessed endpoints.
enum FeedDiscovery {
    static let script = #"""
    const feeds = new Set();
    const mime = /^(application|text)\/(rss|atom)\+xml(?:\s*;|$)/i;
    const add = element => {
      try {
        const url = new URL(element.getAttribute('href'), document.baseURI);
        if (!/^https?:$/.test(url.protocol) || url.username || url.password) return;
        url.hash = '';
        feeds.add(url.href);
      } catch (_) {}
    };
    for (const link of document.querySelectorAll('link[href]')) {
      if (mime.test(link.getAttribute('type') || '')) add(link);
      if (feeds.size >= 10) break;
    }
    for (const link of Array.from(document.querySelectorAll('a[href],area[href]')).slice(0, 5000)) {
      if (feeds.size >= 10) break;
      try {
        const url = new URL(link.getAttribute('href'), document.baseURI);
        const label = [link.textContent, link.getAttribute('title'), link.getAttribute('aria-label'),
          link.querySelector('img')?.getAttribute('alt')].filter(Boolean).join(' ');
        const typed = mime.test(link.getAttribute('type') || '');
        const feedPath = /(?:^|\/)(?:rss|atom|feeds?)(?:\/|\.|$)|\.(?:rss|atom)$/i.test(url.pathname);
        const labelled = /\b(?:rss|atom)\b/i.test(label);
        if (typed || feedPath || labelled) add(link);
      } catch (_) {}
    }
    return Array.from(feeds).slice(0, 10);
    """#
}
