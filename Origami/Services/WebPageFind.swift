import WebKit

/// Search decorations are independent of the webpage's editable text selection.
@MainActor enum WebPageFind {
    static let world = WKContentWorld.world(name: "Origami.Find")
    static func update(_ webView: WKWebView, query: String, step: Int = 0) async throws -> Int {
        let result = try await webView.callAsyncJavaScript(source, arguments: ["query": query, "step": step], in: nil, contentWorld: world)
        let count = (result as? NSNumber)?.intValue ?? 0
        if count == 0, !query.isEmpty, !Task.isCancelled {
            // Preserve WebKit's ability to find text in cross-origin frames and
            // other content unavailable to the DOM highlighter.
            let configuration = WKFindConfiguration()
            configuration.backwards = step < 0
            let native = try await webView.find(query, configuration: configuration)
            return native.matchFound ? 1 : 0
        }
        return count
    }
    static let source = #"""
    if (!window.__origamiFind) {
      const suffix = crypto.randomUUID().replaceAll('-', '');
      const allName = 'origami-find-' + suffix, activeName = allName + '-active';
      let documents = [], matches = [], current = 0, previous = null;
      function clear() {
        for (const {doc, sheet} of documents) {
          doc.defaultView.CSS.highlights.delete(allName);
          doc.defaultView.CSS.highlights.delete(activeName);
          doc.adoptedStyleSheets = doc.adoptedStyleSheets.filter(s => s !== sheet);
        }
        documents = []; matches = []; current = 0;
      }
      function collect(doc, query) {
        const win = doc.defaultView;
        if (!win?.CSS?.highlights || !win.Highlight || !doc.body) return;
        const sheet = new win.CSSStyleSheet();
        sheet.replaceSync(`::highlight(${allName}) { background-color: #ffe580; color: #171717; }
          ::highlight(${activeName}) { background-color: #ffad42; color: #171717; }`);
        doc.adoptedStyleSheets = [...doc.adoptedStyleSheets, sheet];
        documents.push({doc, sheet});
        const nodes = []; let text = '', previousBlock = null;
        const walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT);
        let node, visited = 0;
        while ((node = walker.nextNode()) && ++visited < 100000 && text.length < 2000000) {
          const parent = node.parentElement;
          if (!parent || parent.closest('script,style,noscript,input,textarea,select,[contenteditable],[hidden],[aria-hidden="true"]')) continue;
          if (!parent.getClientRects().length || win.getComputedStyle(parent).visibility !== 'visible') continue;
          let block = parent;
          while (block.parentElement && win.getComputedStyle(block).display === 'inline') block = block.parentElement;
          if (previousBlock && previousBlock !== block) text += '\n';
          previousBlock = block;
          nodes.push({node, start:text.length, end:text.length + node.length}); text += node.data;
        }
        const escaped = query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
        const regex = new RegExp(escaped, 'giu');
        const ranges = []; let match, cursor = 0;
        while ((match = regex.exec(text)) && matches.length < 5000) {
          const start = match.index, end = start + match[0].length;
          while (cursor < nodes.length && nodes[cursor].end <= start) cursor++;
          const first = nodes[cursor]; let lastIndex = cursor;
          while (lastIndex < nodes.length && nodes[lastIndex].end < end) lastIndex++;
          const last = nodes[lastIndex];
          if (!first || !last || first.start > start) continue;
          const range = doc.createRange();
          range.setStart(first.node, start-first.start); range.setEnd(last.node, end-last.start);
          ranges.push(range); matches.push({doc, range});
        }
        win.CSS.highlights.set(allName, new win.Highlight(...ranges));
        for (const frame of doc.querySelectorAll('iframe,frame')) {
          try { if (frame.contentDocument) collect(frame.contentDocument, query); } catch { }
        }
      }
      window.__origamiFind = (query, step) => {
        if (!query) { clear(); previous = null; return 0; }
        if (query !== previous || !step || matches.some(m => !m.range.startContainer.isConnected)) {
          clear(); collect(document, query); previous = query;
        } else if (matches.length) current = (current + step + matches.length) % matches.length;
        for (const {doc} of documents) doc.defaultView.CSS.highlights.delete(activeName);
        const active = matches[current];
        if (active) {
          const win = active.doc.defaultView;
          const highlight = new win.Highlight(active.range); highlight.priority = 1;
          win.CSS.highlights.set(activeName, highlight);
          const rect = active.range.getBoundingClientRect();
          if (rect.top < 0 || rect.bottom > win.innerHeight) {
            active.range.startContainer.parentElement.scrollIntoView({block:'center', inline:'nearest'});
          }
        }
        return matches.length;
      };
    }
    return window.__origamiFind(query, step);
    """#
}
