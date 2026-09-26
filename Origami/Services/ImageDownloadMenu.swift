import AppKit
import WebKit

/// Public WebKit download entry points, including image saves which otherwise lack a public delegate callback.
@MainActor final class ImageDownloadMenu: NSObject, WKScriptMessageHandler {
    static let world = WKContentWorld.world(name: "Origami.ImageDownload")
    private static let handler = "origamiImageDownload"
    weak var webView: WKWebView?
    var allowed: ((URL?) -> Bool)?
    var save: ((URL) -> Void)?
    var open: ((URL) -> Void)?
    var openWindow: ((URL, Bool) -> Void)?
    private var selectedURL: URL?
    private var selectedLink: URL?
    private var selectedFrame: WKFrameInfo?
    private var selectedToken: String?

    func install(on webView: WKWebView) {
        self.webView = webView
        let controller = webView.configuration.userContentController
        controller.add(self, contentWorld: Self.world, name: Self.handler)
        controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentStart,
                                             forMainFrameOnly: false, in: Self.world))
    }
    func dispose() {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.handler, contentWorld: Self.world)
        selectedURL = nil; selectedLink = nil; selectedFrame = nil; selectedToken = nil
        save = nil; open = nil; openWindow = nil; allowed = nil
    }
    static func imageURL(_ value: String) -> URL? {
        guard value.utf8.count <= 20_000_000, let url = URL(string: value),
              ["https", "http", "data", "blob"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil else { return nil }
        return url
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let webView, message.webView === webView, let window = webView.window, window.isKeyWindow,
              let body = message.body as? [String: Any] else { return }
        selectedURL = (body["url"] as? String).flatMap(Self.imageURL)
        selectedLink = (body["link"] as? String).flatMap(Self.imageURL)
        guard selectedURL != nil || selectedLink != nil else { return }
        selectedFrame = message.frameInfo; selectedToken = body["token"] as? String
        defer { selectedURL = nil; selectedLink = nil; selectedFrame = nil; selectedToken = nil }
        let menu = NSMenu(); menu.autoenablesItems = false
        func item(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = NSMenuItem(title: L10n.string(title), action: action, keyEquivalent: "")
            item.target = self; item.isEnabled = enabled; menu.addItem(item)
        }
        let canSave = allowed?(message.frameInfo.request.url) == true
        if selectedLink != nil {
            item("Open Link in New Tab", #selector(openLink), enabled: open != nil)
            item("Open Link in New Window", #selector(openLinkWindow), enabled: openWindow != nil)
            item("Open Link in Private Window", #selector(openLinkPrivate), enabled: openWindow != nil)
            item("Save Link As…", #selector(saveLink), enabled: canSave)
            item("Copy Link Address", #selector(copyLink))
        }
        if selectedURL != nil {
            if selectedLink != nil { menu.addItem(.separator()) }
            item("Open Image in New Tab", #selector(openImage), enabled: open != nil)
            item("Save Image As…", #selector(saveImage), enabled: canSave)
            item("Copy Image", #selector(copyImage), enabled: message.frameInfo.isMainFrame)
            item("Copy Image Address", #selector(copyAddress))
        }
        menu.popUp(positioning: nil, at: webView.convert(window.mouseLocationOutsideOfEventStream, from: nil), in: webView)
    }
    @objc private func saveImage() { if let selectedURL { save?(selectedURL) } }
    @objc private func openImage() { if let selectedURL { open?(selectedURL) } }
    @objc private func openLink() { if let selectedLink { open?(selectedLink) } }
    @objc private func saveLink() { if let selectedLink { save?(selectedLink) } }
    @objc private func openLinkWindow() { if let selectedLink { openWindow?(selectedLink, false) } }
    @objc private func openLinkPrivate() { if let selectedLink { openWindow?(selectedLink, true) } }
    @objc private func copyLink() { copy(selectedLink) }
    @objc private func copyAddress() { copy(selectedURL) }
    private func copy(_ url: URL?) {
        guard let url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
    @objc private func copyImage() {
        guard let webView, let frame = selectedFrame, let token = selectedToken else { return }
        let sourceURL = webView.url
        Task { @MainActor in
            guard let result = try? await webView.callAsyncJavaScript(
                "return window.__origamiContextImage(token);", arguments: ["token": token], in: frame, contentWorld: Self.world) as? [String: Any],
                  webView.url == sourceURL else { return }
            if let encoded = result["data"] as? String, let data = Data(base64Encoded: encoded), let image = NSImage(data: data) {
                NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image]); return
            }
            // Cross-origin pixels cannot be read by canvas. Copy their displayed appearance via WebKit.
            guard frame.isMainFrame, let x = result["x"] as? Double, let y = result["y"] as? Double,
                  let width = result["width"] as? Double, let height = result["height"] as? Double,
                  [x,y,width,height].allSatisfy(\.isFinite), width > 0, height > 0 else { return }
            let rect = CGRect(x: x * webView.pageZoom, y: y * webView.pageZoom, width: width * webView.pageZoom, height: height * webView.pageZoom).intersection(webView.bounds)
            guard !rect.isEmpty else { return }
            let configuration = WKSnapshotConfiguration(); configuration.rect = rect
            if let image = try? await webView.takeSnapshot(configuration: configuration), webView.url == sourceURL {
                NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image])
            }
        }
    }
    static let script = """
    (() => {
      let selected = null, serial = 0;
      window.__origamiContextImage = token => {
        if (!selected || selected.token !== token || !selected.image?.isConnected) return null;
        const image = selected.image;
        const r = image.getBoundingClientRect();
        const result = {x:r.x,y:r.y,width:r.width,height:r.height};
        try {
          if (image.naturalWidth * image.naturalHeight <= 16000000) {
            const canvas = document.createElement('canvas');
            canvas.width = image.naturalWidth; canvas.height = image.naturalHeight;
            canvas.getContext('2d').drawImage(image,0,0);
            result.data = canvas.toDataURL('image/png').split(',')[1];
          }
        } catch (_) {}
        return result;
      };
      document.addEventListener('contextmenu', event => {
        if (!event.isTrusted) return;
        const path = event.composedPath();
        // Preserve native text editing, selection and media menus.
        if (path.some(n => n instanceof HTMLInputElement || n instanceof HTMLTextAreaElement || n.isContentEditable) || getSelection()?.toString()) return;
        const image = path.find(n => n instanceof HTMLImageElement);
        const anchor = path.find(n => n instanceof HTMLAnchorElement);
        const valid = value => /^(https?:|data:|blob:)/i.test(value || '') && value.length <= 20000000;
        const url = image?.currentSrc || image?.src || '';
        const link = anchor?.href || '';
        if (!valid(url) && !valid(link)) return;
        event.preventDefault();
        const token = String(++serial); selected = {image,token};
        window.webkit.messageHandlers.origamiImageDownload.postMessage({url:valid(url)?url:'',link:valid(link)?link:'',token});
      }, true);
    })();
    """
}
