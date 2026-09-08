import SwiftUI
import AppKit

// Native field editors and WebKit can own focus outside SwiftUI's focus system.
@MainActor @Observable
final class BrowserWindowState {
    @ObservationIgnored weak var window: NSWindow?
    private var focusRevision = 0
    var isFullScreen = false
    var showingPreferences = false
    var profileStore: BrowserStore?
    var isKey: Bool {
        // Invalidate menu presentation on focus events, but route actions using AppKit's current responder.
        _ = focusRevision
        return window != nil && window === NSApp.keyWindow
    }
    func refreshFocus() { focusRevision += 1 }
    func attach(_ window: NSWindow?, layout: TabLayout, savedFrame: String?, onboarding: Bool = false) {
        let isNewWindow = self.window !== window
        self.window = window
        if isNewWindow, let window, let savedFrame {
            let frame = NSRectFromString(savedFrame)
            if frame.width >= 760, frame.height >= 500, frame.width <= 10000, frame.height <= 10000,
               NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
                window.setFrame(frame, display: false)
            }
        }
        window?.titleVisibility = .hidden
        window?.titlebarAppearsTransparent = true
        window?.titlebarSeparatorStyle = .none
        window?.styleMask.insert(.fullSizeContentView)
        window?.isOpaque = false
        window?.backgroundColor = .clear
        isFullScreen = window?.styleMask.contains(.fullScreen) == true
        window?.toolbar?.isVisible = !onboarding && layout == .horizontal && !isFullScreen
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            window?.standardWindowButton(kind)?.isHidden = isFullScreen
        }
        refreshFocus()
    }
}

struct BrowserWindowReader: NSViewRepresentable {
    let state: BrowserWindowState
    let layout: TabLayout
    let savedFrame: String?
    var onboarding = false
    func makeNSView(context: Context) -> WindowReaderView { WindowReaderView() }
    func updateNSView(_ view: WindowReaderView, context: Context) {
        view.onWindowChange = { [weak state] window in
            DispatchQueue.main.async { state?.attach(window, layout: layout, savedFrame: savedFrame, onboarding: onboarding) }
        }
        if let window = view.window { view.onWindowChange?(window) }
    }
}

final class WindowReaderView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let window {
            for name in [NSWindow.willEnterFullScreenNotification, NSWindow.didEnterFullScreenNotification,
                         NSWindow.didExitFullScreenNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(fullScreenChanged), name: name, object: window)
            }
        }
        onWindowChange?(window)
    }
    @objc private func fullScreenChanged(_ notification: Notification) {
        // Prepare before AppKit detaches hidden chrome for the full-screen transition.
        if notification.name == NSWindow.willEnterFullScreenNotification {
            window?.toolbar?.isVisible = false
        } else {
            onWindowChange?(window)
        }
    }
}

// AppKit-provided controls stay in the browser chrome while the system's
// fullscreen toolbar is hidden. Actions still belong to the real NSWindow.
struct FullScreenWindowButtons: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 70, height: 28))
        for (index, kind) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let button = NSWindow.standardWindowButton(kind, for: [.titled, .closable, .miniaturizable, .resizable]) else { continue }
            button.setFrameOrigin(NSPoint(x: index * 20 + 5, y: 7))
            button.target = context.coordinator
            button.action = index == 0 ? #selector(Coordinator.close(_:)) : #selector(Coordinator.leaveFullScreen(_:))
            button.isEnabled = index != 1
            view.addSubview(button)
        }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject {
        @objc func close(_ sender: NSButton) { sender.window?.performClose(sender) }
        @objc func leaveFullScreen(_ sender: NSButton) { sender.window?.toggleFullScreen(sender) }
    }
}
