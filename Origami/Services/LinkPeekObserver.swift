import WebKit

@MainActor final class LinkPeekObserver: NSObject, WKScriptMessageHandler {
    var linkBounds: CGRect?
    var changed: ((URL?, CGPoint) -> Void)?
    static func canPreview(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased()) else { return false }
        guard url.user == nil, url.password == nil else { return false }
        if isVideoLink(url) { return false }
        if PeekPreview.documentType(url) != nil { return true }
        let files = Set("pdf zip gz tar dmg pkg exe msi doc docx xls xlsx ppt pptx csv txt json xml rss atom png jpg jpeg gif webp svg avif ico mp3 mp4 mov webm wav ogg woff woff2 ttf".split(separator: " ").map(String.init))
        if files.contains(url.pathExtension.lowercased()) { return false }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return url.path != "/imgres" && !query.contains { $0.name == "imgurl" }
    }
    static func isVideoLink(_ url: URL, unwrap: Bool = true) -> Bool {
        let host = url.host?.lowercased() ?? ""
        func site(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        let path = url.path.lowercased()
        if ["mp4", "m4v", "mov", "webm", "avi", "mkv", "m3u8", "mpd"].contains(url.pathExtension.lowercased()) { return true }
        if site("youtu.be") || site("tiktok.com") { return true }
        if site("youtube.com") || site("youtube-nocookie.com") {
            if path == "/watch" || ["/shorts/", "/embed/", "/live/", "/v/"].contains(where: path.hasPrefix) { return true }
        }
        if site("vimeo.com"), url.pathComponents.contains(where: { !$0.isEmpty && $0.allSatisfy(\.isNumber) }) { return true }
        if site("dailymotion.com"), path.hasPrefix("/video/") { return true }
        if unwrap, path == "/url" || path == "/redirect" {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            return items.contains { item in
                guard ["q", "url", "target"].contains(item.name), let value = item.value, let target = URL(string: value) else { return false }
                return isVideoLink(target, unwrap: false)
            }
        }
        return false
    }
    static let world = WKContentWorld.world(name: "Origami.LinkHover")
    // A favicon/thumbnail inside a titled link is not an image-gallery interaction.
    static let isGalleryLinkSource = """
    (link) => {
      if (!link) return false;
      const pageURL = new URL(location.href);
      if (pageURL.searchParams.get('tbm') === 'isch' || pageURL.searchParams.get('udm') === '2') return true;
      if (link.closest('[aria-roledescription=carousel],[aria-roledescription=slide]')) return true;
      const hasImage = !!link.querySelector('img,picture');
      return hasImage && (!link.textContent.trim() || !!link.closest('[role=dialog]'));
    }
    """
    static let source = """
    (() => {
      let timer, activeLink = null, lastPreview = 0;
      const send = value => window.webkit.messageHandlers.origamiLinkHover.postMessage(value);
      const isGalleryLink = \(isGalleryLinkSource);
      document.addEventListener('pointerover', event => {
        if (!event.isTrusted || event.pointerType !== 'mouse') return;
        const link = event.target.closest?.('a[href]');
        if (isGalleryLink(link)) {
          clearTimeout(timer); activeLink = null; send({}); return;
        }
        if (link === activeLink) return;
        activeLink = link; clearTimeout(timer); send({});
        if (!link || !/^https?:/.test(link.href) || link.hasAttribute('download')) return;
        if (link.closest('nav,footer,header,[role=navigation],[role=contentinfo],[role=tablist],[role=menu],[role=button]')) return;
        if (/(pagination|pager|social|share|footer|breadcrumb)/i.test(String(link.className)+' '+link.id+' '+String(link.parentElement?.className))) return;
        if (/^(next|previous|prev|back|more|sign in|log in|\\d+)$/i.test(link.textContent.trim()) || /next|prev/.test(link.rel)) return;
        const target = new URL(link.href);
        // File eligibility belongs to canPreview(_:), including native document/image previews.
        if (/^(audio|video)\\//i.test(link.type)) return;
        if (target.searchParams.has('imgurl') || target.pathname === '/imgres') return;
        if (target.origin === location.origin && (target.pathname === location.pathname || target.searchParams.has('page') || target.searchParams.has('start'))) return;
        if (/(^|\\.)(facebook\\.com|instagram\\.com|twitter\\.com|x\\.com|tiktok\\.com|linkedin\\.com|whatsapp\\.com|t\\.me)$/.test(target.hostname)) return;
        timer = setTimeout(() => {
          const r = link.getBoundingClientRect();
          if (activeLink !== link || r.bottom <= 0 || r.top >= innerHeight) return;
          lastPreview = performance.now();
          send({url: link.href, x: r.left / innerWidth, y: r.bottom / innerHeight, top: r.top / innerHeight, width: r.width / innerWidth, height: r.height / innerHeight});
        }, performance.now() - lastPreview < 1500 ? 180 : 650);
      }, true);
      document.addEventListener('pointerout', event => {
        const next = event.relatedTarget?.closest?.('a[href]');
        if (next === activeLink) return;
        clearTimeout(timer); activeLink = null; send({});
      }, true);
      document.addEventListener('scroll', () => { clearTimeout(timer); activeLink = null; send({}); }, true);
      document.addEventListener('pointerdown', () => { clearTimeout(timer); activeLink = null; send({}); }, true);
    })();
    """
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any] else { return }
        guard let text = body["url"] as? String, text.count < 8192, let url = URL(string: text),
              Self.canPreview(url), let x = body["x"] as? Double, let y = body["y"] as? Double,
              x.isFinite, y.isFinite else { linkBounds = nil; changed?(nil, .zero); return }
        if let top = body["top"] as? Double, let width = body["width"] as? Double, let height = body["height"] as? Double, top.isFinite, width.isFinite, height.isFinite, width >= 0, height >= 0 {
            linkBounds = CGRect(x: x, y: top, width: width, height: height)
        } else { linkBounds = nil }
        changed?(url, CGPoint(x: max(0,min(x,1)), y: max(0,min(y,1))))
    }
}
