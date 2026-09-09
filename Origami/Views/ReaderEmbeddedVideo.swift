import SwiftUI
import WebKit

/// Runs only the remote player in an isolated, nonpersistent WebView with no native bridges.
struct ReaderEmbeddedVideo: NSViewRepresentable {
    let url: URL
    let pageURL: URL?

    static func html(url: URL) -> String {
        let source = url.absoluteString.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;")
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; frame-src https:; base-uri 'none'; form-action 'none'">
        <style>html,body,iframe{margin:0;width:100%;height:100%;border:0;background:transparent}body{overflow:hidden}</style>
        </head><body><iframe src="\(source)" title="Article video" referrerpolicy="strict-origin-when-cross-origin"
        sandbox="allow-scripts allow-same-origin allow-presentation" allow="fullscreen; picture-in-picture" allowfullscreen></iframe></body></html>
        """
    }
    static func baseURL(_ url: URL?) -> URL? {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https" else { return nil }
        components.user = nil; components.password = nil; components.query = nil; components.fragment = nil; components.path = "/"
        return components.url
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        let key = url.absoluteString + (Self.baseURL(pageURL)?.absoluteString ?? "")
        guard context.coordinator.loadedKey != key else { return }
        context.coordinator.loadedKey = key
        context.coordinator.loadingShell = true
        view.loadHTMLString(Self.html(url: url), baseURL: Self.baseURL(pageURL))
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.pauseAllMediaPlayback()
        view.stopLoading()
        view.navigationDelegate = nil
        view.loadHTMLString("", baseURL: nil)
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedKey: String?
        var loadingShell = false
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.targetFrame?.isMainFrame == true {
                if loadingShell && navigationAction.navigationType == .other {
                    loadingShell = false; decisionHandler(.allow)
                } else { decisionHandler(.cancel) }
            } else if navigationAction.targetFrame != nil,
                      let url = navigationAction.request.url,
                      (url.scheme == "https" && url.user == nil && url.password == nil) || url.absoluteString == "about:blank" {
                decisionHandler(.allow)
            } else { decisionHandler(.cancel) }
        }
    }
}
