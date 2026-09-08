import SwiftUI

struct SuggestionList: View {
    let engine: SuggestionEngine
    let store: BrowserStore
    let activate: (Suggestion) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(engine.results) { suggestion in
                        Button { activate(suggestion) } label: {
                            HStack(spacing: 9) {
                                icon(suggestion).frame(width: 18, height: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(suggestion.title).font(.system(size: 12)).lineLimit(1)
                                    if !suggestion.isSearch && !suggestion.detail.isEmpty {
                                        Text(suggestion.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                                if suggestion.kind == .bookmark { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.secondary) }
                            }.padding(.horizontal, 9).frame(height: 38).frame(maxWidth: .infinity, alignment: .leading)
                                .background(engine.selectedID == suggestion.id ? Personalization.shared.accent.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).id(suggestion.id)
                            .transition(.opacity)
                            .accessibilityLabel(suggestion.title + (suggestion.kind == .bookmark ? ", Bookmark" : ""))
                            .accessibilityAddTraits(engine.selectedID == suggestion.id ? .isSelected : [])
                    }
                }.padding(6)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: engine.results.map(\.id))
            }.onChange(of: engine.selectedID) { if let id = engine.selectedID { proxy.scrollTo(id) } }
        }.frame(height: min(CGFloat(engine.results.count * 40 + 12), 252))
    }
    @ViewBuilder private func icon(_ suggestion: Suggestion) -> some View {
        if !suggestion.isSearch, let url = URL(string: suggestion.input),
           let image = store.services?.favicons.cached(url, profile: store.session.profileID) {
            Image(nsImage: image).resizable().scaledToFit()
        } else { Image(systemName: suggestion.isSearch ? "magnifyingglass" : "globe").foregroundStyle(.secondary) }
    }
}

/// A borderless child window keeps suggestions anchored below either native search field,
/// without a popover arrow or taking keyboard focus away from the editor.
@MainActor final class SuggestionDropdown {
    let panel: NSPanel = {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        return panel
    }()
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []

    func show(below field: NSView, engine: SuggestionEngine, store: BrowserStore,
              activate: @escaping (Suggestion) -> Void, dismiss: @escaping () -> Void) {
        guard let window = field.window else { return }
        let rect = window.convertToScreen(field.convert(field.bounds, to: nil))
        let height = min(CGFloat(engine.results.count * 40 + 12), 252)
        let bounds = window.screen?.visibleFrame ?? window.frame
        let width = min(rect.width, bounds.width)
        let x = min(max(rect.minX, bounds.minX), bounds.maxX - width)
        let available = max(0, rect.minY - 4 - bounds.minY)
        guard available >= 40 else { hide(); return }
        let visibleHeight = min(height, available)
        let frame = NSRect(x: x, y: rect.minY - 4 - visibleHeight, width: width, height: visibleHeight)
        let appearing = panel.parent !== window
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if appearing || reduceMotion {
            panel.setFrame(frame, display: true)
        } else if panel.frame != frame {
            // Keep the top edge attached to the search field as remote results arrive.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                panel.animator().setFrame(frame, display: true)
            }
        }
        if appearing {
            hide()
            panel.contentView = NSHostingView(rootView:
                SuggestionList(engine: engine, store: store, activate: activate)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .clipShape(RoundedRectangle(cornerRadius: 10)))
            window.addChildWindow(panel, ordered: .above)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
                if event.window !== self?.panel { dismiss() }
                return event
            }
            for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
                         NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
                    MainActor.assumeIsolated { dismiss() }
                })
            }
        }
        if appearing { panel.alphaValue = reduceMotion ? 1 : 0 }
        panel.orderFront(nil)
        if appearing && !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                panel.animator().alphaValue = 1
            }
        }
    }
    func hide() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        panel.contentView = nil
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }
}

/// Measures the whole capsule, including its icons and padding, without intercepting input.
@MainActor final class SuggestionAnchor {
    weak var view: NSView?
}

struct SuggestionAnchorView: NSViewRepresentable {
    let anchor: SuggestionAnchor
    func makeNSView(context: Context) -> NSView {
        let view = PassiveSuggestionAnchorView()
        anchor.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}

private final class PassiveSuggestionAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
