import Foundation
import CoreFoundation
import UniformTypeIdentifiers
import WebKit

/// Unpacks WebKit's in-memory archive into ordinary, locally linked files.
/// Only generated filenames are used; website paths never become filesystem paths.
struct PageFolderExport {
    struct Resource {
        let url: String
        let mime: String
        let encoding: String?
        let path: String
        var data: Data
    }
    var resources: [Resource]
    var missing = Set<String>()
    var paths: [String: String] { Dictionary(resources.map { ($0.url, $0.path) }, uniquingKeysWith: { first, _ in first }) }

    init(archive: Data) throws {
        guard archive.count <= 150 * 1024 * 1024,
              let root = try PropertyListSerialization.propertyList(from: archive, format: nil) as? [String: Any] else {
            throw RepositoryError.invalidInput
        }
        var collected: [Resource] = []
        var seen = Set<String>()
        var bytes = 0
        func add(_ item: [String: Any], main: Bool = false) throws {
            guard let url = item["WebResourceURL"] as? String, let data = item["WebResourceData"] as? Data else { return }
            guard seen.insert(url).inserted else { return }
            bytes += data.count
            guard bytes <= 100 * 1024 * 1024, collected.count < 2000 else { throw RepositoryError.invalidInput }
            let mime = Self.resourceMIME(item["WebResourceMIMEType"] as? String, url: url)
            let ext = Self.resourceExtension(mime: mime, url: url)
            let path = main ? "index.html" : "assets/resource-\(collected.count).\(ext)"
            collected.append(Resource(url: url, mime: mime, encoding: item["WebResourceTextEncodingName"] as? String, path: path, data: data))
        }
        func visit(_ node: [String: Any], depth: Int = 0) throws {
            guard depth < 16 else { throw RepositoryError.invalidInput }
            if let main = node["WebMainResource"] as? [String: Any] { try add(main, main: depth == 0) }
            for item in node["WebSubresources"] as? [[String: Any]] ?? [] { try add(item) }
            for frame in node["WebSubframeArchives"] as? [[String: Any]] ?? [] { try visit(frame, depth: depth + 1) }
        }
        try visit(root)
        guard collected.first?.path == "index.html", ["text/html", "application/xhtml+xml"].contains(collected.first?.mime ?? "") else { throw RepositoryError.invalidInput }
        resources = collected
    }

    static func resourceMIME(_ value: String?, url: String) -> String {
        let mime = value?.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if !mime.isEmpty && mime != "application/octet-stream" && mime != "binary/octet-stream" { return mime }
        let ext = URL(string: url)?.pathExtension.lowercased() ?? ""
        let common = ["css": "text/css", "js": "text/javascript", "mjs": "text/javascript", "html": "text/html", "woff": "font/woff", "woff2": "font/woff2", "svg": "image/svg+xml"]
        return common[ext] ?? UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }
    static func resourceExtension(mime: String, url: String) -> String {
        let common = ["text/css": "css", "text/html": "html", "application/xhtml+xml": "html", "text/javascript": "js", "application/javascript": "js", "image/svg+xml": "svg", "font/woff": "woff", "font/woff2": "woff2", "application/font-woff": "woff"]
        if let ext = common[mime] ?? UTType(mimeType: mime)?.preferredFilenameExtension, ext != "bin" { return ext }
        let ext = URL(string: url)?.pathExtension.lowercased() ?? ""
        return !ext.isEmpty && ext.count <= 12 && ext.allSatisfy({ $0.isASCII && $0.isLetter || $0.isNumber }) ? ext : "bin"
    }

    @MainActor static func capture(in webView: WKWebView, html: String, archive: Data) async throws -> Self {
        var original = try Self(archive: archive)
        var attempted = Set<String>()
        var result = original
        let deadline = Date().addingTimeInterval(30)
        // Re-run from original bytes after collecting CSS imports/fonts/images; never rewrite local paths twice.
        for pass in 0..<4 {
            result = original
            for index in original.resources.indices {
                let resource = original.resources[index]
                guard ["text/html", "application/xhtml+xml", "text/css"].contains(resource.mime) else { continue }
                guard let source = index == 0 ? html : Self.decode(resource),
                      let value = try await webView.callAsyncJavaScript(rewriteScript,
                        arguments: ["source": source, "kind": resource.mime == "text/css" ? "css" : "html", "baseURL": resource.url,
                                    "paths": original.paths, "prefix": index == 0 ? "" : "../"],
                        in: nil, contentWorld: .defaultClient) as? [String: Any], let text = value["text"] as? String else { throw RepositoryError.invalidInput }
                result.resources[index].data = Data(text.utf8)
                result.missing.formUnion(value["missing"] as? [String] ?? [])
            }
            guard pass < 3 else { break }
            var added = false
            for address in result.missing.sorted() where attempted.count < 80 {
                guard Date() < deadline, !Task.isCancelled else { break }
                guard attempted.insert(address).inserted,
                      let url = ReaderMedia.safeURL(address),
                      let loaded = await PageExportResourceLoader.load(url) else { continue }
                guard original.resources.count < 2000,
                      original.resources.reduce(0, { $0 + $1.data.count }) + loaded.data.count <= 100 * 1024 * 1024 else { break }
                let mime = resourceMIME(loaded.mime, url: address)
                let expected = resourceMIME(nil, url: address)
                if mime == "text/html" && expected != "application/octet-stream" && expected != "text/html" { continue }
                let path = "assets/resource-\(original.resources.count).\(resourceExtension(mime: mime, url: address))"
                original.resources.append(Resource(url: address, mime: mime, encoding: loaded.encoding, path: path, data: loaded.data))
                added = true
            }
            if !added { break }
        }
        return result
    }

    static func decode(_ resource: Resource) -> String? {
        if let name = resource.encoding {
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId,
               let value = String(data: resource.data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))) { return value }
        }
        return String(data: resource.data, encoding: .utf8)
    }

    func write(to parent: URL, fileManager: FileManager = .default) throws -> URL {
        let staging = parent.appendingPathComponent(".origami-export-" + UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.createDirectory(at: staging.appendingPathComponent("assets", isDirectory: true), withIntermediateDirectories: false)
        for resource in resources {
            try resource.data.write(to: staging.appendingPathComponent(resource.path), options: .atomic)
        }
        var index = 1
        var destination = parent.appendingPathComponent("Page", isDirectory: true)
        while fileManager.fileExists(atPath: destination.path) {
            index += 1
            destination = parent.appendingPathComponent("Page \(index)", isDirectory: true)
        }
        // A racing destination causes failure, never replacement of another export.
        try fileManager.moveItem(at: staging, to: destination)
        return destination
    }

    /// Runs in WebKit's isolated world on a detached DOM. No extra network requests.
    static let rewriteScript = #"""
    const missing = new Set();
    function local(value, base) {
      if (!value || /^(data:|#)/i.test(value.trim())) return value;
      try {
        const url = new URL(value, base), fragment = url.hash; url.hash = '';
        const path = paths[url.href] || paths[new URL(value, base).href];
        if (path) return prefix + path + fragment;
        missing.add(url.href);
        return ''; // Never silently refetch missing assets from the original website.
      } catch (_) { missing.add(value); return ''; }
    }
    function css(value, base) {
      return value.replace(/@charset\s+["'][^"']*["']\s*;/gi, '').replace(/url\(\s*(?:"([^"\n]*)"|'([^'\n]*)'|([^)'"\s][^)]*?))\s*\)/gi,
        (_, a, b, c) => 'url(' + JSON.stringify(local(a ?? b ?? c, base)) + ')')
        .replace(/(@import\s+)(["'])(.*?)\2/gi, (_, start, quote, url) => start + JSON.stringify(local(url, base)));
    }
    if (kind === 'css') return {text: css(source, baseURL), missing: [...missing]};
    function rewriteHTML(source, baseURL, depth = 0) {
    if (depth > 8) { missing.add('nested-frame'); return ''; }
    const doc = new DOMParser().parseFromString(source, 'text/html');
    const base = new URL(doc.querySelector('base[href]')?.getAttribute('href') || baseURL, baseURL).href;
    doc.querySelectorAll('script, base, meta[http-equiv], meta[charset], link[rel="preload"], link[rel="prefetch"], link[rel="modulepreload"]').forEach(n => n.remove());
    const meta = doc.createElement('meta'); meta.setAttribute('charset', 'utf-8'); doc.head.prepend(meta);
    function elements(root) { return [...root.querySelectorAll('*')].flatMap(node => node.tagName === 'TEMPLATE' ? [node, ...elements(node.content)] : [node]); }
    for (const node of elements(doc)) {
      if (node.tagName === 'SCRIPT') { node.remove(); continue; }
      if (node.hasAttribute('data-origami-unavailable')) missing.add(node.getAttribute('data-origami-unavailable')); 
      for (const attr of [...node.attributes]) if (/^on/i.test(attr.name)) node.removeAttribute(attr.name);
      if (node.hasAttribute('style')) node.setAttribute('style', css(node.getAttribute('style'), base));
      if (node.tagName === 'STYLE') node.textContent = css(node.textContent, base);
      for (const attr of ['src', 'poster', 'background', 'data']) {
        if (node.hasAttribute(attr)) { const value = local(node.getAttribute(attr), base); if (value) node.setAttribute(attr, value); else node.removeAttribute(attr); }
      }
      if (node.hasAttribute('srcdoc')) node.setAttribute('srcdoc', rewriteHTML(node.getAttribute('srcdoc'), base, depth + 1));
      if (node.hasAttribute('srcset')) {
        // The captured currentSrc is used instead of choosing another network variant offline.
        node.removeAttribute('srcset');
      }
      if (node.tagName === 'LINK' || ['image', 'use'].includes(node.localName)) {
        for (const attr of ['href', 'xlink:href']) if (node.hasAttribute(attr)) { const value = local(node.getAttribute(attr), base); if (value) node.setAttribute(attr, value); else node.removeAttribute(attr); }
        node.removeAttribute('integrity'); node.removeAttribute('crossorigin');
      } else if (node.hasAttribute('href')) {
        const href = node.getAttribute('href');
        if (!href.startsWith('#')) { try { node.setAttribute('href', new URL(href, base).href); } catch (_) {} }
      }
      if (node.tagName === 'FORM') { node.removeAttribute('action'); node.setAttribute('onsubmit', 'return false'); }
      if (node.tagName === 'INPUT' && !['button', 'submit', 'reset'].includes(node.type)) { node.removeAttribute('value'); node.removeAttribute('checked'); }
      if (node.tagName === 'TEXTAREA') node.textContent = '';
      node.removeAttribute('autoplay');
    }
    return '<!DOCTYPE html>\n' + doc.documentElement.outerHTML;
    }
    const text = rewriteHTML(source, baseURL);
    return {text, missing: [...missing]};
    """#
}
