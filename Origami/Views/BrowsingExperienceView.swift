import SwiftUI

struct BrowsingExperienceView: View {
    let store: BrowserStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fraction = 0.5
    @State private var dragStart: Double?
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if let split = store.session.split {
                    HStack(spacing: 0) {
                        pane(split.left).frame(width: max(0, (geometry.size.width - 6) * fraction))
                        Color.clear.frame(width: 6).contentShape(Rectangle())
                            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                            .gesture(DragGesture().onChanged { value in
                                if dragStart == nil { dragStart = fraction }
                                fraction = max(0.25, min(0.75, (dragStart ?? 0.5) + value.translation.width / max(1, geometry.size.width)))
                            }.onEnded { _ in dragStart = nil })
                            .accessibilityLabel("Split divider")
                            .accessibilityAdjustableAction { direction in fraction = max(0.25,min(0.75,fraction + (direction == .increment ? 0.05 : -0.05))) }
                        pane(split.right).frame(maxWidth: .infinity)
                    }
                    .task(id: split) { _ = store.page(for: split.left); _ = store.page(for: split.right) }
                } else { BrowserContentView(store: store) }
                if let peek = store.peekPage {
                    let paneOffset = store.session.split?.right == store.peekSourceID ? geometry.size.width * fraction + 6 : 0
                    let paneWidth = store.session.split == nil ? geometry.size.width : geometry.size.width * (paneOffset == 0 ? fraction : 1 - fraction)
                    let anchor = store.peekLinkBounds ?? CGRect(x: store.peekAnchor.x, y: store.peekAnchor.y, width: 0, height: 0)
                    let link = CGRect(x: paneOffset + anchor.minX * paneWidth, y: anchor.minY * geometry.size.height, width: anchor.width * paneWidth, height: anchor.height * geometry.size.height)
                    if let frame = PeekLayout.frame(viewport: store.peekViewport, link: link, container: geometry.size) {
                        PeekDismissMonitor(preview: frame, dismiss: store.dismissPeek).allowsHitTesting(false)
                        PeekThumbnail(page: peek, viewport: store.peekViewport)
                            .id(peek.tabID)
                            .frame(width: frame.width, height: frame.height)
                            .background(Color(nsColor: .textBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 10))
                            .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
                            .offset(x: frame.minX, y: frame.minY).transition(.opacity)
                            .onExitCommand { store.dismissPeek() }
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: store.session.split != nil)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: store.peekPage != nil)
        .onChange(of: store.selectedTab?.id) { store.dismissPeek() }
    }
    private func pane(_ id: UUID) -> some View {
        BrowserContentView(store: store, tabID: id)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: BrowserChromeMetrics.contentCornerRadius))
            .simultaneousGesture(TapGesture().onEnded { store.select(id) })
    }
}

private struct PeekDismissMonitor: NSViewRepresentable {
    var preview: CGRect
    var dismiss: () -> Void
    func makeNSView(context: Context) -> Monitor { Monitor() }
    func updateNSView(_ view: Monitor, context: Context) { view.preview = preview; view.dismiss = dismiss }
    final class Monitor: NSView {
        var preview = CGRect.zero
        var dismiss: (() -> Void)?
        var token: Any?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let token { NSEvent.removeMonitor(token); self.token = nil }
            guard window != nil else { return }
            token = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                let inside = self.preview.contains(self.convert(event.locationInWindow, from: nil))
                self.dismiss?()
                return inside && event.type != .scrollWheel ? nil : event
            }
        }
        deinit { if let token { NSEvent.removeMonitor(token) } }
    }
}
