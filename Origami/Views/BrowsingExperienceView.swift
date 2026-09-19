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
                } else {
                    BrowserContentView(store: store)
                        .modifier(PageSplitDropSurface(store: store, id: store.session.selectedTabID))
                }
                if let peek = store.peekPage {
                    let paneOffset = store.session.activeSplit?.right == store.peekSourceID ? availableWidth * liveFraction + 6 : 0
                    let paneWidth = store.session.activeSplit == nil ? geometry.size.width : availableWidth * (paneOffset == 0 ? liveFraction : 1 - liveFraction)
                    let anchor = store.peekLinkBounds ?? CGRect(x: store.peekAnchor.x, y: store.peekAnchor.y, width: 0, height: 0)
                    let link = CGRect(x: paneOffset + anchor.minX * paneWidth, y: anchor.minY * geometry.size.height, width: anchor.width * paneWidth, height: anchor.height * geometry.size.height)
                    if let frame = PeekLayout.frame(viewport: store.peekViewport, link: link, container: geometry.size) {
                        PeekDismissMonitor(preview: frame, dismiss: store.dismissPeek, interaction: { inside in
                            store.peekInteracting = inside
                            if inside { store.peekDismissGeneration = UUID() }
                            else if store.peekSourceID != nil { store.deferPeekDismissal() }
                        }).allowsHitTesting(false)
                        PeekCard(page: peek, url: store.peekURL ?? peek.currentURL ?? URL(string: "about:blank")!,
                                 viewport: store.peekViewport, mode: store.peekMode,
                                 open: store.promotePeek, dismiss: store.dismissPeek, swiping: { active in
                                     store.peekSwiping = active
                                     if !active, !store.peekInteracting, store.peekSourceID != nil { store.deferPeekDismissal() }
                                 })
                        .id(peek.tabID)
                        .frame(width: frame.width, height: frame.height)
                        .contentShape(Rectangle())
                        .offset(x: frame.minX, y: frame.minY).transition(.opacity)
                        .onExitCommand { store.dismissPeek() }
                    }
                }
            }
        }
        .onPreferenceChange(PageDropFramePreference.self) { store.pageDropFrames = $0 }
        .onDisappear { store.pageDropFrames = [:]; store.splitDropPreview = nil }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: store.session.activeSplit != nil)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: store.peekPage != nil)
        .onChange(of: store.selectedTab?.id) { store.dismissPeek() }
    }
    private func pane(_ id: UUID) -> some View {
        BrowserContentView(store: store, tabID: id)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: BrowserChromeMetrics.contentCornerRadius))
            .simultaneousGesture(TapGesture().onEnded { store.select(id) })
            .modifier(PageSplitDropSurface(store: store, id: id))
    }
}

private struct PeekDismissMonitor: NSViewRepresentable {
    var preview: CGRect
    var dismiss: () -> Void
    var interaction: (Bool) -> Void
    func makeNSView(context: Context) -> Monitor { Monitor() }
    func updateNSView(_ view: Monitor, context: Context) {
        view.preview = preview; view.dismiss = dismiss; view.interaction = interaction; view.updateTrackingAreas()
    }
    final class Monitor: NSView {
        var preview = CGRect.zero
        var dismiss: (() -> Void)?
        var interaction: ((Bool) -> Void)?
        private var tracking: NSTrackingArea?
        private var scrolling = PeekScrollInteraction()
        var token: Any?
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if tracking?.rect == preview { return }
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: preview, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
            addTrackingArea(area); tracking = area
        }
        override func mouseEntered(with event: NSEvent) { interaction?(true) }
        override func mouseExited(with event: NSEvent) { interaction?(false) }
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let token { NSEvent.removeMonitor(token); self.token = nil }
            guard window != nil else { return }
            token = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                guard let window = self.window else { return event }
                let point = self.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
                let inside = self.preview.contains(point)
                if event.type == .scrollWheel {
                    let dismiss = self.scrolling.shouldDismiss(inside: inside,
                        began: event.phase.contains(.began) || event.phase.isEmpty,
                        ended: event.phase.contains(.ended) || event.phase.contains(.cancelled) || event.phase.isEmpty,
                        momentum: !event.momentumPhase.isEmpty)
                    if event.momentumPhase.isEmpty { self.interaction?(inside) }
                    if dismiss { self.dismiss?() }
                } else if !inside { self.dismiss?() }
                return event
            }
        }
        deinit { if let token { NSEvent.removeMonitor(token) } }
    }
}

private struct PageSplitDropSurface: ViewModifier {
    @Environment(\.profileAppearance) private var appearance
    let store: BrowserStore
    let id: UUID?
    func body(content: Content) -> some View {
        content.overlay {
            GeometryReader { geometry in
                if let id {
                    Color.clear.preference(key: PageDropFramePreference.self,
                                           value: [id: geometry.frame(in: .global)])
                    if let target = store.splitDropPreview, target.pageID == id {
                        RoundedRectangle(cornerRadius: BrowserChromeMetrics.contentCornerRadius)
                            .fill(appearance.accent.opacity(0.18))
                            .overlay { RoundedRectangle(cornerRadius: BrowserChromeMetrics.contentCornerRadius)
                                .strokeBorder(appearance.accent, lineWidth: 2) }
                            .frame(width: geometry.size.width / 2)
                            .offset(x: target.onLeft ? 0 : geometry.size.width / 2)
                    }
                }
            }.allowsHitTesting(false)
        }
    }
}

private struct PageDropFramePreference: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}
