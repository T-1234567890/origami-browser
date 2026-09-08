import SwiftUI
import AppKit

struct Omnibox: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    let store: BrowserStore
    let allowRemote: Bool
    var tabID: UUID?
    var value: String
    var focusRequest: UUID
    var canFocus = true
    var suggestionsEnabled = true
    var suggestionAnchor: SuggestionAnchor?
    var editingChanged: (Bool) -> Void = { _ in }
    var placeholder = "Search or enter URL"
    var fontSize: CGFloat = 13
    var textChanged: (String) -> Void = { _ in }
    var navigate: (String, Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> AddressField {
        let field = AddressField()
        field.usesSingleLineMode = true
        field.maximumNumberOfLines = 1
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.lineBreakMode = .byClipping
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.placeholderString = placeholder
        field.isBezeled = false
        field.drawsBackground = false
        field.font = .systemFont(ofSize: fontSize)
        field.focusRingType = .none
        field.delegate = context.coordinator
        context.coordinator.field = field
        field.setAccessibilityIdentifier("omnibox")
        field.setAccessibilityLabel(placeholder)
        field.willFocus = { [weak coordinator = context.coordinator, weak field] in
            if let field { coordinator?.beginEditing(field) }
        }
        field.didFocus = { [weak coordinator = context.coordinator, weak field] in
            if let field { coordinator?.styleEditor(field) }
        }
        field.submit = { [weak coordinator = context.coordinator] text, search in coordinator?.completeEditing(submission: (text, search)) }
        return field
    }
    func updateNSView(_ field: AddressField, context: Context) {
        context.coordinator.parent = self
        context.coordinator.scheduleUpdate(field)
    }
    static func dismantleNSView(_ nsView: AddressField, coordinator: Coordinator) {
        nsView.delegate = nil; nsView.willFocus = nil; nsView.didFocus = nil; nsView.submit = nil
        coordinator.active = false
        coordinator.suggestions.cancelPending()
        DispatchQueue.main.async { coordinator.dismissSuggestions() }
    }
    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var active = true
        private var updateScheduled = false
        private var editingNotificationScheduled = false
        private var pendingEditing = false
        func scheduleUpdate(_ field: AddressField) {
            // AppKit focus changes can synchronously invoke delegates. Reconcile after the SwiftUI update.
            if remoteAllowed != parent.allowRemote { suggestions.cancelPending() }
            guard !updateScheduled else { return }
            updateScheduled = true
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self, let field else { return }
                self.updateScheduled = false
                guard self.active else { return }
                self.reconcile(field)
            }
        }
        private func reconcile(_ field: AddressField) {
            field.placeholderString = parent.placeholder
            field.appearance = NSAppearance(named: parent.colorScheme == .dark ? .darkAqua : .aqua)
            if !parent.suggestionsEnabled { dismissSuggestions() }
            if remoteAllowed != parent.allowRemote {
                remoteAllowed = parent.allowRemote; dismissSuggestions()
            }
            if lastTabID != parent.tabID {
                dismissSuggestions(); lastTabID = parent.tabID
                if editing { field.window?.makeFirstResponder(nil) }
                editing = false; reportEditing(false)
            }
            if !editing { field.stringValue = OmniboxPresentation.displayValue(parent.value) }
            if !parent.canFocus && lastFocus == nil { lastFocus = parent.focusRequest }
            if parent.canFocus && lastFocus != parent.focusRequest {
                lastFocus = parent.focusRequest
                field.window?.makeFirstResponder(field); field.selectText(nil)
            }
        }
        func reportEditing(_ value: Bool) {
            pendingEditing = value
            guard !editingNotificationScheduled else { return }
            editingNotificationScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.editingNotificationScheduled = false
                guard self.active else { return }
                self.parent.editingChanged(self.pendingEditing)
            }
        }
        weak var field: NSTextField?
        let suggestions = SuggestionEngine()
        let dropdown = SuggestionDropdown()
        var remoteAllowed = false
        func dismissSuggestions() { suggestions.stop(); dropdown.hide() }
        func refreshSuggestions(_ field: NSTextField) {
            guard parent.suggestionsEnabled else { dismissSuggestions(); return }
            suggestions.changed = { [weak self, weak field] in
                guard let self, let field, self.editing else { return }
                if self.suggestions.results.isEmpty { self.dropdown.hide(); return }
                self.dropdown.show(below: self.parent.suggestionAnchor?.view ?? field, engine: self.suggestions, store: self.parent.store,
                                   activate: { [weak self] in self?.activate($0) },
                                   dismiss: { [weak self] in self?.dismissSuggestions() })
            }
            let bookmarks = parent.store.services.map { BookmarkSuggestionProvider(repository: $0.bookmarks, profileID: parent.store.session.profileID) }
            suggestions.update(field.stringValue, bookmarks: bookmarks, engine: parent.store.session.searchEngine, allowRemote: remoteAllowed)
        }
        func activate(_ suggestion: Suggestion) {
            completeEditing(submission: (suggestion.input, suggestion.isSearch))
        }
        private var completionPending = false
        func completeEditing(submission: (String, Bool)? = nil) {
            guard active, !completionPending else { return }
            completionPending = true
            dismissSuggestions()
            let tabID = parent.tabID
            let focusRequest = parent.focusRequest
            let navigate = parent.navigate
            // Finish AppKit's field-editor command before changing responders or
            // starting WebKit navigation. Navigation can replace this field.
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self else { return }
                self.completionPending = false
                guard self.active, self.parent.tabID == tabID,
                      self.parent.focusRequest == focusRequest else { return }
                if let field, let window = field.window,
                   window.firstResponder === field || window.firstResponder === field.currentEditor() {
                    window.makeFirstResponder(nil)
                }
                self.editing = false
                self.reportEditing(false)
                if let submission { navigate(submission.0, submission.1) }
            }
        }
        var parent: Omnibox
        var editing = false
        var lastFocus: UUID?
        var lastTabID: UUID?
        init(_ parent: Omnibox) { self.parent = parent }
        func beginEditing(_ field: NSTextField) {
            guard !editing else { return }
            editing = true
            field.stringValue = OmniboxPresentation.editingValue(parent.value)
            reportEditing(true)
        }
        func styleEditor(_ field: NSTextField) {
            guard let editor = field.currentEditor() as? NSTextView else { return }
            let foreground: NSColor = parent.colorScheme == .dark ? .white : .black
            let fullRange = NSRange(location: 0, length: (editor.string as NSString).length)
            editor.textStorage?.addAttribute(.foregroundColor, value: foreground, range: fullRange)
            let length = OmniboxPresentation.schemeLength(editor.string)
            if length > 0 { editor.textStorage?.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: 0, length: length)) }
            editor.typingAttributes[.foregroundColor] = foreground
        }
        func controlTextDidBeginEditing(_ obj: Notification) {
            // Focus, rather than the first keystroke, expands the displayed address.
            editing = true; reportEditing(true)
            if let field = obj.object as? NSTextField { styleEditor(field) }
        }
        func controlTextDidChange(_ obj: Notification) {
            if let field = obj.object as? NSTextField {
                parent.textChanged(field.stringValue)
                styleEditor(field)
                if (field.currentEditor() as? NSTextView)?.hasMarkedText() != true { refreshSuggestions(field) }
            }
        }
        func controlTextDidEndEditing(_ obj: Notification) {
            if NSApp.currentEvent?.window !== dropdown.panel { dismissSuggestions() }
            editing = false; reportEditing(false)
            (obj.object as? NSTextField)?.stringValue = OmniboxPresentation.displayValue(parent.value)
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let field = control as? NSTextField else { return false }
            if selector == #selector(NSResponder.moveDown(_:)) || selector == #selector(NSResponder.moveUp(_:)) {
                if suggestions.results.isEmpty { refreshSuggestions(field) }
                suggestions.moveSelection(selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1)
                return !suggestions.results.isEmpty
            }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                if let selected = suggestions.selected { activate(selected); return true }
                completeEditing(submission: (field.stringValue, false))
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                if !suggestions.results.isEmpty { dismissSuggestions(); return true }
                field.stringValue = OmniboxPresentation.displayValue(parent.value)
                completeEditing()
                return true
            }
            return false
        }
    }
}

final class AddressField: NSTextField {
    var submit: ((String, Bool) -> Void)?
    var willFocus: (() -> Void)?
    var didFocus: (() -> Void)?
    override func becomeFirstResponder() -> Bool {
        willFocus?()
        let accepted = super.becomeFirstResponder()
        if accepted { didFocus?() }
        return accepted
    }
    override func mouseDown(with event: NSEvent) {
        willFocus?()
        super.mouseDown(with: event)
        didFocus?()
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        menu.addItem(.separator())
        for (title, action) in [("Paste and Go", #selector(pasteAndGo)), ("Paste and Search", #selector(pasteAndSearch))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; menu.addItem(item)
        }
        return menu
    }
    @objc func pasteAndGo() { pasteNavigation(search: false) }
    @objc func pasteAndSearch() { pasteNavigation(search: true) }
    private func pasteNavigation(search: Bool) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        submit?(text, search)
    }
}
