import SwiftUI

struct BrowsingExperienceView: View {
    let store: BrowserStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fraction = 0.5
    @GestureState private var dragTranslation: CGFloat = 0
    var body: some View {
        GeometryReader { geometry in
            let availableWidth = max(0, geometry.size.width - 6)
            let liveFraction = max(0.25, min(0.75, fraction + dragTranslation / max(1, availableWidth)))
            ZStack(alignment: .topLeading) {
                if let split = store.session.activeSplit {
                    HStack(spacing: 0) {
                        pane(split.left).frame(width: max(0, availableWidth * liveFraction))
                        Color.clear.frame(width: 6).contentShape(Rectangle())
                            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                            // The divider moves while resizing, so its local coordinates are unstable.
                            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                                .updating($dragTranslation) { value, translation, _ in translation = value.translation.width }
                                .onEnded { value in
                                    fraction = max(0.25, min(0.75, fraction + value.translation.width / max(1, availableWidth)))
                                })
                            .accessibilityLabel("Split divider")
                            .accessibilityAdjustableAction { direction in fraction = max(0.25,min(0.75,fraction + (direction == .increment ? 0.05 : -0.05))) }
                        pane(split.right).frame(width: availableWidth * (1 - liveFraction))
                    }
                    .task(id: split) { _ = store.page(for: split.left); _ = store.page(for: split.right) }
                } else { BrowserContentView(store: store) }
                if let peek = store.peekPage {
                    let paneOffset = store.session.activeSplit?.right == store.peekSourceID ? availableWidth * liveFraction + 6 : 0
                    let paneWidth = store.session.activeSplit == nil ? geometry.size.width : availableWidth * (paneOffset == 0 ? liveFraction : 1 - liveFraction)
                    let anchor = store.peekLinkBounds ?? CGRect(x: store.peekAnchor.x, y: store.peekAnchor.y, width: 0, height: 0)
                    let link = CGRect(x: paneOffset + anchor.minX * paneWidth, y: anchor.minY * geometry.size.height, width: anchor.width * paneWidth, height: anchor.height * geometry.size.height)
                    if let frame = PeekLayout.frame(viewport: store.peekViewport, link: link, container: geometry.size) {
                        let panel = AISettings.shared.aiPeekActive ? PeekLayout.aiPanelFrame(preview: frame, link: link, container: geometry.size) : nil
                        let combined = panel.map { frame.union($0) } ?? frame
                        PeekDismissMonitor(preview: combined, dismiss: store.dismissPeek).allowsHitTesting(false)
                        ZStack(alignment: .topLeading) {
                            PeekThumbnail(page: peek, viewport: store.peekViewport)
                                .frame(width: frame.width, height: frame.height)
                                .background(Color(nsColor: .textBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
                                .offset(x: frame.minX - combined.minX, y: frame.minY - combined.minY)
                            if let panel {
                                PeekAIResults(store: store, page: peek)
                                    .frame(width: panel.width, height: panel.height)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
                                    .offset(x: panel.minX - combined.minX, y: panel.minY - combined.minY)
                            }
                        }
                        .id(peek.tabID)
                        .frame(width: combined.width, height: combined.height, alignment: .topLeading)
                        .contentShape(Rectangle())
                        .offset(x: combined.minX, y: combined.minY).transition(.opacity)
                        .onExitCommand { store.dismissPeek() }
                        .onHover { inside in
                            store.peekInteracting = inside
                            if !inside, store.peekSourceID != nil { store.deferPeekDismissal() }
                        }
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: store.session.activeSplit != nil)
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
                if !inside { self.dismiss?() }
                return event
            }
        }
        deinit { if let token { NSEvent.removeMonitor(token) } }
    }
}
