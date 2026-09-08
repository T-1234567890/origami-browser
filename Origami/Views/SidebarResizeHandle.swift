import SwiftUI
import AppKit

struct SidebarResizeHandle: NSViewRepresentable {
    @Binding var width: CGFloat
    var resizingChanged: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> SidebarDividerView {
        SidebarDividerView()
    }

    func updateNSView(_ view: SidebarDividerView, context: Context) {
        view.sidebarWidth = width
        view.resizingChanged = resizingChanged
        view.resize = { newWidth in
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { width = newWidth }
        }
    }
}

final class SidebarDividerView: NSView {
    var sidebarWidth: CGFloat = 240
    var resize: ((CGFloat) -> Void)?
    var resizingChanged: ((Bool) -> Void)?
    private var dragOrigin: (x: CGFloat, width: CGFloat)?

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        dragOrigin = (event.locationInWindow.x, sidebarWidth)
        resizingChanged?(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOrigin else { return }
        // Window coordinates stay fixed while the divider itself moves during resizing.
        let proposed = dragOrigin.width + event.locationInWindow.x - dragOrigin.x
        let limits = BrowserChromeMetrics.sidebarWidthRange
        resize?(min(limits.upperBound, max(limits.lowerBound, proposed)))
    }

    override func mouseUp(with event: NSEvent) { dragOrigin = nil; resizingChanged?(false) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if dragOrigin != nil { resizingChanged?(false) }
        dragOrigin = nil
    }
}

struct SidebarPopoverPreference: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}
