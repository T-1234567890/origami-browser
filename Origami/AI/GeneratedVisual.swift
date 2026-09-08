import SwiftUI
import WebKit
import Foundation

/// Deliberately small XHTML subset: parser validation, not regex HTML sanitization.
enum VisualPolicy {
    static func valid(_ value: AnswerVisual) -> Bool { rejection(value) == nil }
    static func rejection(_ value: AnswerVisual) -> String? {
        if value.html.isEmpty { return "html.empty_or_schema_rejected" }
        if value.html.utf8.count > 24_000 { return "html.size_limit" }
        if value.css.utf8.count > 12_000 { return "css.size_limit" }
        if value.javascript.utf8.count > 24_000 { return "javascript.size_limit" }
        let css = value.css.lowercased(), js = value.javascript.lowercased()
        for token in ["url", "@import", "\\", "expression", "</style"] where css.contains(token) { return "css.disallowed_token: " + token }
        for token in ["</script", "eval(", "function(", "while", "for(", "for (", "webkit", "messagehandlers", "fetch", "xmlhttprequest", "websocket", "worker", "webassembly", "window.open", "localstorage", "indexeddb", "document.cookie", "import("] where js.contains(token) { return "javascript.disallowed_token: " + token }
        // Keyword checks also catch comments/newlines between a loop keyword and
        // its condition. This is admission defense, not a CPU-time guarantee.
        if js.range(of: #"\b(for|while|do)\b"#, options: .regularExpression) != nil { return "javascript.loop_keyword" }
        let delegate = FragmentValidator()
        let parser = XMLParser(data: Data(("<root>" + value.html + "</root>").utf8)); parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        let parsed = parser.parse()
        return delegate.reason ?? (parsed ? nil : "html.malformed_xml line=\(parser.lineNumber) column=\(parser.columnNumber) code=\((parser.parserError as NSError?)?.code ?? 0)")
    }
    static func document(_ visual: AnswerVisual) -> String {
        let nonce = UUID().uuidString
        let csp = "default-src 'none'; script-src 'nonce-\(nonce)'; style-src 'nonce-\(nonce)'; connect-src 'none'; img-src 'none'; frame-src 'none'; child-src 'none'; worker-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'; media-src 'none'"
        let html = "<!doctype html><html><head><meta http-equiv=\"Content-Security-Policy\" content=\"\(csp)\"><style nonce=\"\(nonce)\">:root{color-scheme:light dark}body{margin:0;font:14px system-ui;overflow:hidden}*{box-sizing:border-box}#visual{max-height:480px;overflow:hidden}\(visual.css)</style></head><body><div id=\"visual\">\(visual.html)</div><script nonce=\"\(nonce)\">'use strict';\n\(visual.javascript)</script></body></html>"
        return html
    }
    static func configuration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController.addUserScript(WKUserScript(source: """
        window.__origamiVisualFailed=false;
        addEventListener('error',()=>{window.__origamiVisualFailed=true;window.__origamiVisualReason='javascript.runtime_error'},true);
        addEventListener('unhandledrejection',()=>{window.__origamiVisualFailed=true;window.__origamiVisualReason='javascript.unhandled_rejection'},true);
        addEventListener('securitypolicyviolation',()=>{window.__origamiVisualFailed=true;window.__origamiVisualReason='csp.violation'},true);
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
        return config
    }
    private final class FragmentValidator: NSObject, XMLParserDelegate {
        var reason: String?
        private var count = 0
        private let tags = Set("root div span p h1 h2 h3 ul ol li strong em b i br button label input canvas section article table thead tbody tr th td".split(separator: " ").map(String.init))
        private let attributes = Set("id class type min max step value width height role aria-label aria-hidden for tabindex".split(separator: " ").map(String.init))
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes values: [String: String]) {
            count += 1
            if !tags.contains(name) { reason = "html.unsupported_tag" }
            else if count > 300 { reason = "html.node_limit" }
            else if values.keys.contains(where: { !attributes.contains($0) }) { reason = "html.unsupported_attribute" }
            if reason != nil { parser.abortParsing(); return }
            if name == "input", let type = values["type"], !["range", "number", "checkbox", "radio", "button"].contains(type) { reason = "html.disallowed_input_type"; parser.abortParsing() }
        }
        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { reason = "html.entity_declaration"; parser.abortParsing() }
        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { reason = "html.entity_declaration"; parser.abortParsing() }
    }
}

struct GeneratedVisualView: View {
    let visual: AnswerVisual
    @State private var height: CGFloat = 0
    @State private var failure = false
    var body: some View {
        if failure || !VisualPolicy.valid(visual) {
            Text("Interactive visual couldn’t be displayed.").font(.caption).foregroundStyle(.secondary)
                .onAppear { if let reason = VisualPolicy.rejection(visual) { VisualDiagnostics.shared.record(reason) } }
        } else {
            VisualWebHost(visual: visual, height: $height, failure: $failure)
                .frame(height: height).opacity(height > 0 ? 1 : 0).clipped()
                .accessibilityHidden(height == 0)
        }
    }
}
struct VisualWebHost: NSViewRepresentable {
    let visual: AnswerVisual
    @Binding var height: CGFloat
    var failure: Binding<Bool> = .constant(false)
    func makeCoordinator() -> Coordinator { Coordinator(height: $height, failure: failure) }
    func makeNSView(context: Context) -> Host {
        let host = Host(); guard VisualPolicy.valid(visual) else { return host }
        let config = VisualPolicy.configuration()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 480), configuration: config)
        view.navigationDelegate = context.coordinator; view.uiDelegate = context.coordinator
        host.web = view; host.addSubview(view); context.coordinator.web = view; context.coordinator.host = host
        view.loadHTMLString(VisualPolicy.document(visual), baseURL: nil); context.coordinator.start()
        return host
    }
    func updateNSView(_ nsView: Host, context: Context) { }
    static func dismantleNSView(_ nsView: Host, coordinator: Coordinator) { coordinator.dispose() }
    final class Host: NSView {
        var web: WKWebView?
        override func layout() { super.layout(); web?.frame = CGRect(x: 0, y: 0, width: max(300, bounds.width), height: 480) }
    }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var height: Binding<CGFloat>
        var failure: Binding<Bool>
        weak var web: WKWebView?
        weak var host: Host?
        var timer: Timer?
        var started = Date(); var pending: Date?; var loaded = false; var failed = false
        init(height: Binding<CGFloat>, failure: Binding<Bool> = .constant(false)) { self.height = height; self.failure = failure }
        func start() {
            started = Date()
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.check() } }
        }
        func fail(_ reason: String = "renderer.invalid_status") {
            guard !failed else { return }
            VisualDiagnostics.shared.record(reason)
            failure.wrappedValue = true
            dispose()
        }
        func dispose() {
            failed = true; timer?.invalidate(); timer = nil
            pending = nil; loaded = false
            height.wrappedValue = 0
            // Break every Origami-owned reference, including the host's strong
            // reference. Never reuse a failed environment for another visual.
            let discarded = web
            web = nil
            host?.web = nil; host = nil
            discarded?.navigationDelegate = nil; discarded?.uiDelegate = nil
            discarded?.configuration.userContentController.removeAllUserScripts()
            discarded?.stopLoading()
            discarded?.removeFromSuperview()
            // Public WebKit has no supported force-terminate-process API. Once
            // these references leave scope, WebKit owns process reclamation.
        }
        func check() {
            guard !failed else { return }
            if (!loaded && Date().timeIntervalSince(started) > 4) || pending.map({ Date().timeIntervalSince($0) > (height.wrappedValue == 0 ? 4 : 1) }) == true { fail(loaded ? "renderer.health_check_timeout" : "navigation.load_timeout"); return }
            guard loaded, pending == nil, let web else { return }; pending = Date()
            // The completion API avoids a suspended Swift task retaining web
            // indefinitely while untrusted JavaScript blocks a response.
            web.callAsyncJavaScript("return {failed:window.__origamiVisualFailed === true,reason:window.__origamiVisualReason,height:document.getElementById('visual')?.getBoundingClientRect().height || 0, text:document.body.innerText.length, canvas:!!document.querySelector('canvas')};", arguments: [:], in: nil, in: .defaultClient) { [weak self] result in
                guard let self, !self.failed else { return }
                self.pending = nil
                switch result {
                case .success(let value): self.accept(value)
                case .failure: self.fail("javascript.health_check_execution")
                }
            }
        }
        func accept(_ value: Any) {
            guard !failed else { return }
            if let status = value as? [String: Any], status["failed"] as? Bool == true {
                let reason = status["reason"] as? String ?? "javascript.runtime_error"
                fail(["javascript.runtime_error", "javascript.unhandled_rejection", "csp.violation"].contains(reason) ? reason : "javascript.runtime_error"); return
            }
            guard let status = value as? [String: Any], let h = status["height"] as? Double, h.isFinite, h >= 40, h <= 480, (status["text"] as? Int ?? 0) > 0 || status["canvas"] as? Bool == true else { fail("sizing.invalid_or_empty_frame"); return }
            if height.wrappedValue == 0 { VisualDiagnostics.shared.record("renderer.success") }
            height.wrappedValue = CGFloat(h)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail("navigation.failure code=\((error as NSError).code)") }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail("navigation.failure code=\((error as NSError).code)") }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { fail("renderer.content_process_terminated") }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if !loaded && action.request.url?.scheme == "about" { decisionHandler(.allow) }
            else { decisionHandler(.cancel); fail("navigation.disallowed") }
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { fail("navigation.popup_blocked"); return nil }
    }
}

/// Payloads are available to the debugger only, never printed or written to disk.
final class VisualDiagnostics: @unchecked Sendable {
    static let shared = VisualDiagnostics()
    private let lock = NSLock()
    #if DEBUG
    private(set) var rawResponse = ""
    private(set) var rawVisualPayloads: [Data] = []
    private(set) var stages: [String] = []
    #endif
    func capture(_ response: String, blocks: [[String: Any]], isPrivate: Bool = false) {
        guard !isPrivate else { return }
        #if DEBUG
        lock.lock(); defer { lock.unlock() }
        rawResponse = String(response.prefix(1_000_000))
        rawVisualPayloads = blocks.filter { $0["type"] as? String == "generated_visual" }.prefix(8).compactMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        stages = ["response.visual_count=\(blocks.filter { $0["type"] as? String == "generated_visual" }.count)"]
        NSLog("[Origami Visual] %@", stages[0])
        #endif
    }
    func record(_ reason: String) {
        #if DEBUG
        lock.lock(); defer { lock.unlock() }
        stages.append(reason); if stages.count > 100 { stages.removeFirst() }
        NSLog("[Origami Visual] %@", reason)
        #endif
    }
}
