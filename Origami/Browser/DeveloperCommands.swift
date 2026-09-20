import AppKit
import WebKit

extension BrowserStore {
    func inspectInSafari() {
        guard let page = visiblePage, page.nativePage == nil else { return }
        page.webView.isInspectable = true
        if preferences.safariInspectionInstructionsSeen {
            openSafariForInspection()
            return
        }
        guard let window = nativeWindow, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = L10n.string("Inspect in Safari…")
        alert.informativeText = "Origami pages can be inspected using Safari Web Inspector. In Safari, enable developer features in Settings → Advanced, then use Develop → This Mac → Origami."
        alert.addButton(withTitle: L10n.string("Open Safari"))
        alert.addButton(withTitle: L10n.string("Done"))
        let preferences = preferences
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else { return }
            preferences.safariInspectionInstructionsSeen = true
            if response == .alertFirstButtonReturn { self?.openSafariForInspection() }
        }
    }

    private func openSafariForInspection() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else {
            persistenceError = L10n.string("Safari could not be found on this Mac.")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
            if error != nil {
                Task { @MainActor [weak self] in self?.persistenceError = L10n.string("Safari could not be opened. Please try again.") }
            }
        }
    }
}

