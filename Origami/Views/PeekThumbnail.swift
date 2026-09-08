import SwiftUI
import WebKit

/// A desktop-width, read-only image. The backing page has no visible controls or hit targets.
struct PeekThumbnail: View {
    let page: TabPage
    let viewport: CGSize
    @State private var image: NSImage?
    var body: some View {
        GeometryReader { geometry in
          ZStack {
            PassivePeekPage(webView: page.webView, viewport: viewport)
                .frame(width: viewport.width, height: viewport.height).opacity(0.001).allowsHitTesting(false)
            if let image { Image(nsImage: image).resizable().scaledToFit().frame(width: geometry.size.width, height: geometry.size.height) }
            else { ProgressView().controlSize(.small) }
          }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }.allowsHitTesting(false)
        .task(id: page.isLoading) {
            guard !page.isLoading else { return }
            await page.webView.setAllMediaPlaybackSuspended(true)
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            let config = WKSnapshotConfiguration()
            config.rect = CGRect(origin: .zero, size: viewport)
            config.snapshotWidth = 560
            if let snapshot = try? await page.webView.takeSnapshot(configuration: config), !Task.isCancelled { image = snapshot }
        }
    }
}

// Explicit AppKit pass-through prevents the invisible backing WebView from stealing hover events.
private struct PassivePeekPage: NSViewRepresentable {
    let webView: WKWebView
    let viewport: CGSize
    func makeNSView(context: Context) -> Host { Host() }
    func updateNSView(_ host: Host, context: Context) {
        if webView.superview !== host { webView.removeFromSuperview(); host.addSubview(webView) }
        webView.autoresizingMask = []
        webView.frame = CGRect(origin: .zero, size: viewport)
    }
    final class Host: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
