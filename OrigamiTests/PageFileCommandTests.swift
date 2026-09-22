import Testing
import WebKit
@testable import Origami

@MainActor struct PageFileCommandTests {
    @Test(.timeLimit(.minutes(1))) func printOperationStartsWithValidFrame() async throws {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        webView.loadHTMLString("<html><head><title>Print Fixture</title></head><body>Printable page</body></html>", baseURL: URL(string: "https://example.invalid/print"))
        defer { webView.stopLoading() }
        let deadline = Date().addingTimeInterval(15)
        while webView.isLoading || webView.title != "Print Fixture" {
            guard Date() < deadline else { throw RepositoryError.invalidInput }
            try await Task.sleep(for: .milliseconds(50))
        }
        let session = PagePrintSession(webView: webView, completion: {})
        #expect(session.operation.view?.frame.isEmpty == false)
        #expect(session.operation.canSpawnSeparateThread)
        #expect(session.webView === webView)
        #expect(session.operation.printInfo !== NSPrintInfo.shared)
    }

    @Test(.timeLimit(.minutes(1))) func htmlExportPreservesBaseAndDoesNotMutatePage() async throws {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        defer { webView.stopLoading() }
        webView.loadHTMLString("<html><head><title>Export Fixture</title><base href='https://example.invalid/assets/'></head><body><p>Example</p><input value='fixture-secret'><textarea>fixture-note</textarea><a href='next'>Next</a></body></html>", baseURL: URL(string: "https://example.invalid/page"))
        let deadline = Date().addingTimeInterval(15)
        while webView.isLoading || webView.title != "Export Fixture" {
            guard Date() < deadline else { throw RepositoryError.invalidInput }
            try await Task.sleep(for: .milliseconds(50))
        }
        let html = try #require(try await webView.callAsyncJavaScript(PageHTMLExport.script, arguments: [:], in: nil, contentWorld: .defaultClient) as? String)
        #expect(html.hasPrefix("<!DOCTYPE html>"))
        #expect(html.contains("https://example.invalid/assets/"))
        #expect(html.contains("charset=\"utf-8\""))
        #expect(html.contains("Example</p>"))
        #expect(!html.contains("fixture-secret") && !html.contains("fixture-note"))
        let liveValue = try await webView.evaluateJavaScript("document.querySelector('input').value") as? String
        #expect(liveValue == "fixture-secret")
    }
    @Test(.timeLimit(.minutes(1))) func folderExportRewritesResourcesAndPreservesPreviousExports() async throws {
        func resource(_ url: String, _ mime: String, _ contents: String) -> [String: Any] {
            ["WebResourceURL": url, "WebResourceMIMEType": mime, "WebResourceData": Data(contents.utf8)]
        }
        let archive: [String: Any] = [
            "WebMainResource": resource("https://example.invalid/page", "text/html", "<html></html>"),
            "WebSubresources": [
                resource("https://example.invalid/styles/main.css", "text/css", "@import 'other.css'; body {background:url('../image.png')}"),
                resource("https://example.invalid/styles/other.css", "text/css", "p { color: red; }"),
                resource("https://example.invalid/image.png", "image/png", "fixture-image")
            ]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0)
        var export = try PageFolderExport(archive: data)
        let paths = export.paths
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        webView.loadHTMLString("<html><head><title>Folder Fixture</title></head><body></body></html>", baseURL: URL(string: "https://example.invalid/page"))
        defer { webView.stopLoading() }
        let deadline = Date().addingTimeInterval(15)
        while webView.isLoading || webView.title != "Folder Fixture" {
            guard Date() < deadline else { throw RepositoryError.invalidInput }
            try await Task.sleep(for: .milliseconds(50))
        }
        let html = "<html><head><base href='https://example.invalid/'><link rel='stylesheet' href='styles/main.css'></head><body><img src='image.png'><img src='missing.png'><script>fetch('/remote')</script><a href='/next'>Next</a></body></html>"
        for index in export.resources.indices where ["text/html", "text/css"].contains(export.resources[index].mime) {
            let item = export.resources[index]
            let source = index == 0 ? html : try #require(PageFolderExport.decode(item))
            let value = try #require(try await webView.callAsyncJavaScript(PageFolderExport.rewriteScript,
                arguments: ["source": source, "kind": item.mime == "text/css" ? "css" : "html", "baseURL": item.url,
                            "paths": paths, "prefix": index == 0 ? "" : "../"], in: nil, contentWorld: .defaultClient) as? [String: Any])
            export.resources[index].data = Data(try #require(value["text"] as? String).utf8)
            export.missing.formUnion(value["missing"] as? [String] ?? [])
        }
        let savedHTML = try #require(String(data: export.resources[0].data, encoding: .utf8))
        #expect(savedHTML.contains("assets/resource-1.css") && savedHTML.contains("assets/resource-3.png"))
        #expect(!savedHTML.contains("<base") && !savedHTML.contains("<script"))
        #expect(savedHTML.contains("https://example.invalid/next"))
        #expect(export.missing == ["https://example.invalid/missing.png"])
        let css = try #require(String(data: export.resources[1].data, encoding: .utf8))
        #expect(css.contains("../assets/resource-2.css") && css.contains("../assets/resource-3.png"))
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let first = try export.write(to: parent)
        let second = try export.write(to: parent)
        #expect(first != second)
        #expect(try Data(contentsOf: first.appendingPathComponent("index.html")) == export.resources[0].data)
        #expect(try Data(contentsOf: first.appendingPathComponent("assets/resource-3.png")) == Data("fixture-image".utf8))
    }

    @Test func resourceTypesUseNormalizedMIMEAndURLFallbacks() {
        #expect(PageFolderExport.resourceMIME("Text/CSS; charset=UTF-8", url: "https://example.invalid/style") == "text/css")
        #expect(PageFolderExport.resourceMIME(nil, url: "https://example.invalid/main.css?version=1") == "text/css")
        #expect(PageFolderExport.resourceExtension(mime: "application/octet-stream", url: "https://example.invalid/font.woff2") == "woff2")
        #expect(PageFolderExport.resourceExtension(mime: "image/svg+xml", url: "https://example.invalid/icon") == "svg")
    }

    @Test(.timeLimit(.minutes(1))) func savedSnapshotPreservesDynamicLayoutCanvasAndFramesOffline() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let source = parent.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let html = "<html><head><title>Snapshot Fixture</title><link rel='stylesheet' href='style.css'></head><body><div id='dynamic'>Dynamic</div><canvas width='12' height='12'></canvas><iframe srcdoc='<p>Frame content</p>'></iframe><script>document.querySelector('#dynamic').style.width='123px';document.querySelector('canvas').getContext('2d').fillRect(0,0,12,12);</script></body></html>"
        try Data(html.utf8).write(to: source.appendingPathComponent("index.html"))
        try Data("#dynamic{height:40px;background:rgb(20,40,60);color:white}".utf8).write(to: source.appendingPathComponent("style.css"))
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        defer { view.stopLoading() }
        view.loadFileURL(source.appendingPathComponent("index.html"), allowingReadAccessTo: source)
        let deadline = Date().addingTimeInterval(20)
        while view.isLoading || view.title != "Snapshot Fixture" {
            guard Date() < deadline else { throw RepositoryError.invalidInput }
            try await Task.sleep(for: .milliseconds(50))
        }
        let snapshot = try #require(try await view.callAsyncJavaScript(PageHTMLExport.script, arguments: [:], in: nil, contentWorld: .defaultClient) as? String)
        let archive: Data = try await withCheckedThrowingContinuation { continuation in view.createWebArchiveData { continuation.resume(with: $0) } }
        let export = try await PageFolderExport.capture(in: view, html: snapshot, archive: archive)
        #expect(export.missing.isEmpty)
        let folder = try export.write(to: parent)
        // Remove the original fixture. The exported page must stand on its own.
        try FileManager.default.removeItem(at: source)
        let offline = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        defer { offline.stopLoading() }
        offline.loadFileURL(folder.appendingPathComponent("index.html"), allowingReadAccessTo: folder)
        while offline.isLoading || offline.title != "Snapshot Fixture" {
            guard Date() < deadline else { throw RepositoryError.invalidInput }
            try await Task.sleep(for: .milliseconds(50))
        }
        let metrics = try #require(try await offline.evaluateJavaScript("({width: getComputedStyle(document.querySelector('#dynamic')).width, background: getComputedStyle(document.querySelector('#dynamic')).backgroundColor, canvas: document.querySelector('img')?.src.startsWith('data:image/png'), scripts: document.scripts.length, frame: document.querySelector('iframe').srcdoc.includes('Frame content')})") as? [String: Any])
        #expect(metrics["width"] as? String == "123px")
        #expect(metrics["background"] as? String == "rgb(20, 40, 60)")
        #expect(metrics["canvas"] as? Bool == true)
        #expect(metrics["scripts"] as? Int == 0)
        #expect(metrics["frame"] as? Bool == true)
    }

}
