import SwiftUI
import AppKit
import Carbon

struct BrowserHotKey: Equatable {
    var key: UInt32
    var modifiers: UInt32
    var label: String
}

@MainActor final class GlobalBrowserControls {
    private weak var application: BrowserApplicationContext?
    private var registrations: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var quickPanel: NSPanel?
    private var hiddenByShortcut = false
    private weak var previousKeyWindow: NSWindow?
    var error: String?
    init(application: BrowserApplicationContext) {
        self.application = application
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, pointer in
            guard let pointer else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated {
                let owner = Unmanaged<GlobalBrowserControls>.fromOpaque(pointer).takeUnretainedValue()
                let action = id.id
                // Present after the hot-key event has finished dispatching.
                DispatchQueue.main.async { [weak owner] in
                    if action == 1 { owner?.showSearch() } else if action == 2 { owner?.toggleHide() }
                }
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { error = "Global shortcuts could not be registered on this Mac."; return }
        configure()
    }
    func configure() {
        registrations.forEach { UnregisterEventHotKey($0) }; registrations.removeAll(); error = nil
        guard handler != nil else { error = "Global shortcuts could not be registered on this Mac."; return }
        guard let preferences = application?.persistence?.preferences ?? application?.activeStore?.preferences else { return }
        for (id, enabled, shortcut) in [(UInt32(1), preferences.globalSearchEnabled, preferences.searchHotKey), (UInt32(2), preferences.quickHideEnabled, preferences.hideHotKey)] where enabled {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(shortcut.key, shortcut.modifiers, EventHotKeyID(signature: 0x4F524947, id: id), GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { registrations.append(ref) }
            else { error = "The shortcut \(shortcut.label) is unavailable. Choose another combination." }
        }
    }
    func stop() {
        registrations.forEach { UnregisterEventHotKey($0) }; registrations.removeAll()
        if let handler { RemoveEventHandler(handler); self.handler = nil }
        quickPanel?.close(); quickPanel = nil
    }
    func showSearch() {
        if quickPanel?.isVisible == true { quickPanel?.orderOut(nil); return }
        let panel = QuickSearchPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 68), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating; panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true; panel.becomesKeyOnlyIfNeeded = false
        panel.contentView = NSHostingView(rootView: GlobalSearchField(submit: { [weak self] text in self?.submit(text) }, cancel: { [weak panel] in panel?.orderOut(nil) }))
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let frame = screen?.visibleFrame { panel.setFrameOrigin(NSPoint(x: frame.midX - 280, y: frame.minY + frame.height * 0.68)) }
        quickPanel?.close(); quickPanel = panel
        // A nonactivating panel must also be ordered above the current app when
        // all browser windows are minimized or Origami is in the background.
        panel.orderFrontRegardless()
        panel.makeKey()
    }
    private func submit(_ text: String) {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, let application else { return }
        quickPanel?.orderOut(nil)
        if NSApp.isHidden { NSApp.unhide(nil); hiddenByShortcut = false }
        let store: BrowserStore
        if let existing = application.activeStore { store = existing; _ = store.newTab() }
        else { store = application.newWindow() }
        store.navigate(input)
        NSApp.activate(ignoringOtherApps: true)
        if let window = store.nativeWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
    }
    func toggleHide() {
        if hiddenByShortcut && NSApp.isHidden {
            hiddenByShortcut = false
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
            previousKeyWindow?.makeKeyAndOrderFront(nil)
        } else {
            previousKeyWindow = application?.activeStore?.nativeWindow ?? NSApp.keyWindow
            quickPanel?.orderOut(nil)
            hiddenByShortcut = true
            NSApp.hide(nil)
        }
    }
}
private final class QuickSearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func resignKey() { super.resignKey(); orderOut(nil) }
}
private struct GlobalSearchField: View {
    let submit: (String) -> Void
    let cancel: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            QuickSearchInput(submit: submit, cancel: cancel).frame(height: 28)
        }.padding(.horizontal, 24).frame(height: 60).modifier(ChromeSurface()).padding(4)
    }
}

private struct QuickSearchInput: NSViewRepresentable {
    let submit: (String) -> Void
    let cancel: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> QuickSearchTextField {
        let field = QuickSearchTextField()
        field.placeholderString = "Search or enter URL"
        field.isBezeled = false; field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20)
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Quick Search")
        return field
    }
    func updateNSView(_ field: QuickSearchTextField, context: Context) { context.coordinator.parent = self }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: QuickSearchInput
        init(_ parent: QuickSearchInput) { self.parent = parent }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                let text = control.stringValue, submit = parent.submit
                DispatchQueue.main.async { submit(text) }
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                let cancel = parent.cancel
                DispatchQueue.main.async { cancel() }
                return true
            }
            return false
        }
    }
}
private final class QuickSearchTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Hosting can attach the field before the panel is key. Request focus
        // once presentation is complete, including when Origami is frontmost.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.isVisible, window.isKeyWindow else { return }
            window.makeFirstResponder(self)
        }
    }
}
