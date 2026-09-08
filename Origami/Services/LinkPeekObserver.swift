import WebKit

@MainActor final class LinkPeekObserver: NSObject, WKScriptMessageHandler {
    var linkBounds: CGRect?
    var changed: ((URL?, CGPoint) -> Void)?
    static func canPreview(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased()) else { return false }
        let files = Set("pdf zip gz tar dmg pkg exe msi doc docx xls xlsx ppt pptx csv txt json xml rss atom png jpg jpeg gif webp svg avif ico mp3 mp4 mov webm wav ogg woff woff2 ttf".split(separator: " ").map(String.init))
        if files.contains(url.pathExtension.lowercased()) { return false }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return url.path != "/imgres" && !query.contains { $0.name == "imgurl" }
    }
    static let world = WKContentWorld.world(name: "Origami.LinkHover")
    static let source = """
    (() => {
      let timer, activeLink = null, lastPreview = 0;
      const send = value => window.webkit.messageHandlers.origamiLinkHover.postMessage(value);
      document.addEventListener('pointerover', event => {
        if (!event.isTrusted || event.pointerType !== 'mouse') return;
        const link = event.target.closest?.('a[href]');
        if (link === activeLink) return;
        activeLink = link; clearTimeout(timer); send({});
        if (!link || !/^https?:/.test(link.href) || link.hasAttribute('download')) return;
        if (link.closest('nav,footer,header,[role=navigation],[role=contentinfo],[role=tablist],[role=menu],[role=button]')) return;
        if (/(pagination|pager|social|share|footer|breadcrumb)/i.test(String(link.className)+' '+link.id+' '+String(link.parentElement?.className))) return;
        if (/^(next|previous|prev|back|more|sign in|log in|\\d+)$/i.test(link.textContent.trim()) || /next|prev/.test(link.rel)) return;
        const target = new URL(link.href);
        if (/\\.(pdf|zip|gz|tar|dmg|pkg|exe|msi|docx?|xlsx?|pptx?|csv|txt|json|xml|rss|atom|png|jpe?g|gif|webp|svg|avif|ico|mp[34]|mov|webm|wav|ogg|woff2?|ttf)$/i.test(target.pathname) || /^(image|audio|video)\\//i.test(link.type)) return;
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
