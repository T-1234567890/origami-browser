import SwiftUI
import WebKit

struct WebViewContainer: NSViewRepresentable {
    let webView: WKWebView
    var dismissDialog: () -> Void
    var activated: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(dismissDialog: dismissDialog) }
    final class Coordinator {
        var dismissDialog: () -> Void
        init(dismissDialog: @escaping () -> Void) { self.dismissDialog = dismissDialog }
    }
    static func dismantleNSView(_ nsView: WebContentHost, coordinator: Coordinator) { coordinator.dismissDialog() }
    func makeNSView(context: Context) -> WebContentHost {
        let host = WebContentHost()
        host.wantsLayer = true
        host.layer?.masksToBounds = true
        host.layer?.cornerRadius = BrowserChromeMetrics.contentCornerRadius
        // NSView uses an unflipped coordinate system: maxY is the top edge.
        host.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        return host
    }
    func updateNSView(_ host: WebContentHost, context: Context) {
        if host.subviews.first !== webView { context.coordinator.dismissDialog() }
        context.coordinator.dismissDialog = dismissDialog
        host.activated = activated
        host.attach(webView)
    }
}

/// SwiftUI drives the host frame. Apply every size change directly to WebKit so its
/// CSS viewport and resize events update during live resizing and fullscreen transitions.
final class WebContentHost: NSView {
    var activated: () -> Void = {}
    private var mouseMonitor: Any?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor); self.mouseMonitor = nil }
        guard window != nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            if let self, event.window === self.window, !self.isHiddenOrHasHiddenAncestor,
               self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { self.activated() }
            return event
        }
    }
    deinit { if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizesSubviews = false
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    func attach(_ webView: WKWebView) {
        if subviews.first !== webView {
            subviews.forEach { $0.removeFromSuperview() }
            webView.removeFromSuperview()
            webView.translatesAutoresizingMaskIntoConstraints = true
            webView.autoresizingMask = []
            addSubview(webView)
        }
        synchronizeViewport()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        synchronizeViewport()
    }

    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        synchronizeViewport()
    }

    override func layout() {
        super.layout()
        synchronizeViewport()
    }

    private func synchronizeViewport() {
        guard let webView = subviews.first as? WKWebView, webView.frame != bounds else { return }
        webView.frame = bounds
    }
}
