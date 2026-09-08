import SwiftUI
import AppKit
import Carbon

struct GlobalShortcutSettings: View {
    let store: BrowserStore
    @State private var error: String?
    var body: some View {
        let _ = store.preferencesRevision
        VStack(spacing: 12) {
            HStack {
                Toggle("Global Quick Search", isOn: Binding(get: { store.preferences.globalSearchEnabled }, set: { store.preferences.globalSearchEnabled = $0; update() }))
                ShortcutRecorder(shortcut: store.preferences.searchHotKey) { store.preferences.searchHotKey = $0; update() }.frame(width: 120, height: 26)
            }
            HStack {
                Toggle("Quick Hide", isOn: Binding(get: { store.preferences.quickHideEnabled }, set: { store.preferences.quickHideEnabled = $0; update() }))
                ShortcutRecorder(shortcut: store.preferences.hideHotKey) { store.preferences.hideHotKey = $0; update() }.frame(width: 120, height: 26)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
        }.onAppear { error = store.application?.globalControls?.error }
    }
    private func update() {
        store.preferencesRevision += 1
        store.application?.startGlobalControls()
        store.application?.globalControls?.configure()
        error = store.application?.globalControls?.error
    }
}
private struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: BrowserHotKey
    let changed: (BrowserHotKey) -> Void
    func makeNSView(context: Context) -> ShortcutRecordButton { ShortcutRecordButton() }
    func updateNSView(_ button: ShortcutRecordButton, context: Context) {
        button.changed = changed
        if !button.recording { button.title = shortcut.label }
    }
}
private final class ShortcutRecordButton: NSButton {
    var changed: ((BrowserHotKey) -> Void)?
    var recording = false
    private var previous = ""
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        previous = title; recording = true; title = "Press shortcut…"; window?.makeFirstResponder(self)
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { return }
        if event.keyCode == 53 { title = previous; recording = false; return }
        let flags = event.modifierFlags
        guard flags.contains(.command) || flags.contains(.control) else { title = "Use ⌘ or ⌃"; return }
        var modifiers: UInt32 = 0; var label = ""
        for (flag, carbon, symbol) in [(NSEvent.ModifierFlags.control, controlKey, "⌃"), (.option, optionKey, "⌥"), (.shift, shiftKey, "⇧"), (.command, cmdKey, "⌘")] {
            if flags.contains(flag) { modifiers |= UInt32(carbon); label += symbol }
        }
        label += event.keyCode == 49 ? "Space" : (event.charactersIgnoringModifiers ?? "Key \(event.keyCode)").uppercased()
        recording = false; title = label
        changed?(BrowserHotKey(key: UInt32(event.keyCode), modifiers: modifiers, label: label))
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event); return true
    }
    override func resignFirstResponder() -> Bool { if recording { title = previous; recording = false }; return super.resignFirstResponder() }
}
