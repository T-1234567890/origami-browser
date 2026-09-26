import UniformTypeIdentifiers
import SwiftUI
import WebKit

struct QuickTools: View {
    @Environment(\.profileAppearance) private var appearance
    let store: BrowserStore
    var close: () -> Void
    @State private var error: String?
    @State private var output: String?
    private var page: TabPage? { store.visiblePage }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Quick Tools").font(.headline); Spacer(); Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Close Commands") }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    section("Page") {
                        if page?.jsonText != nil {
                            command(page?.showsJSON == true ? "Show Original Response" : "JSON Reader", "curlybraces") {
                                page?.readerVisible = false
                                page?.showsJSON.toggle()
                                close()
                            }
                        }
                        command(page?.readerVisible == true ? "Exit Reader Mode" : "Reader Mode", "doc.text") { page?.readerVisible.toggle(); close() }.disabled(page?.article == nil)
                        if let manager = store.services?.highlighter {
                            command("Highlighter", "highlighter") { manager.enabled.toggle(); close() }
                                .foregroundStyle(manager.enabled ? appearance.accent : Color.primary)
                                .accessibilityValue(manager.enabled ? "On" : "Off")
                        }
                        command("Find", "magnifyingglass") { close(); if let pdf = page?.pdfContent { pdf.searchVisible = true } else { store.showingFind = true } }
                        command("Save PDF…", "square.and.arrow.down") { savePDF() }
                    }.disabled(page?.nativePage != nil || page == nil)
                    section("RSS") {
                        command("RSS Feeds", InternalPage.feeds.symbol) { close(); store.openInternal(.feeds) }
                        if let feeds = page?.discoveredFeeds, !feeds.isEmpty {
                            ForEach(feeds, id: \.self) { url in
                                command(feeds.count == 1 ? "Subscribe RSS" : "Subscribe RSS · " + url.lastPathComponent, "plus") {
                                    Task {
                                        do { try await store.services?.feeds.follow(url, profile: store.session.profileID); close(); store.openInternal(.feeds) }
                                        catch { self.error = error.localizedDescription }
                                    }
                                }
                            }
                        }
                    }
                    section("Scripts") {
                        ForEach(ScriptRuntime.builtins) { script in command(script.name, "curlybraces") { run(script) }.disabled(page?.nativePage != nil || page == nil) }
                        command("Manage Scripts…", InternalPage.scripts.symbol) { close(); store.openInternal(.scripts) }
                    }
                    if let error { Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(16).frame(width: 290, height: 480)
            .task(id: page?.currentURL) { await page?.discoverDocuments() }
            .sheet(isPresented: Binding(get: { output != nil }, set: { if !$0 { output = nil } })) {
                VStack(alignment: .leading) {
                    Text("Script Result").font(.headline)
                    ScrollView { Text(output ?? "").font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    HStack { Spacer(); Button("Copy") { copyText(output ?? "") }; Button("Done") { output = nil } }
                }.padding(20).frame(width: 540, height: 380)
            }
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) { Text(L10n.string(title)).font(.caption).foregroundStyle(.secondary); content() }.padding(.bottom, 10)
    }
    private func command(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(L10n.string(title), systemImage: icon).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain).padding(.vertical, 3)
    }
    private func run(_ script: UserScript) {
        guard let page else { return }
        Task { do { output = String(try await ScriptRuntime.run(script, page: page).prefix(200000)); error = nil } catch { self.error = error.localizedDescription } }
    }
    private func savePDF() {
        guard let page else { return }
        if let pdf = page.pdfContent { pdf.save(); return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]; panel.nameFieldStringValue = "Page.pdf"
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            Task { do { let data = try await page.webView.pdf(configuration: .init()); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }; try data.write(to: url, options: .atomic) } catch { self.error = error.localizedDescription } }
        }
    }
}

@MainActor func copyText(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }

struct ScriptManager: View {
    let store: BrowserStore
    @State private var scripts: [UserScript] = []
    @State private var draft: UserScript?
    @State private var error: String?
    @State private var result: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Scripts").font(.title2.weight(.semibold)); Spacer(); Button("New Script") { draft = UserScript() } }
            Text("Scripts can read and change matching pages. Only enable code you trust. Changes apply on the next navigation.").font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(scripts) { script in
                    HStack {
                        Toggle(script.name, isOn: Binding(get: { script.enabled }, set: { enabled in var changed = script; changed.enabled = enabled; save(changed) }))
                        Spacer(); Button("Edit") { draft = script }
                        Menu("Run in Tab") {
                            ForEach(runnableTabs) { tab in
                                Button(tab.title) { run(script, in: tab.id) }
                            }
                        }.disabled(runnableTabs.isEmpty)
                            .help("Choose an open webpage to run this script")
                        Button("Delete", role: .destructive) { perform { try store.services?.power.remove(script, profile: store.session.profileID); refreshRuntime() } }
                    }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
            if let result { ScrollView { Text(result).textSelection(.enabled) }.frame(maxHeight: 100); Button("Copy Result") { copyText(result) } }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).task { load() }
            .sheet(item: $draft) { script in ScriptEditor(script: script, error: error) { save($0); if error == nil { draft = nil } } }
    }
    private var runnableTabs: [BrowserTab] {
        store.session.tabs.filter { tab in
            guard let page = store.loadedPage(for: tab.id), page.nativePage == nil,
                  let scheme = page.currentURL?.scheme else { return false }
            return scheme == "https" || scheme == "http"
        }
    }
    private func run(_ script: UserScript, in id: UUID) {
        guard runnableTabs.contains(where: { $0.id == id }), let page = store.loadedPage(for: id) else { return }
        Task {
            do { result = String(try await ScriptRuntime.run(script, page: page).prefix(200000)); error = nil }
            catch { self.error = error.localizedDescription }
        }
    }
    private func load() { perform { scripts = try store.services?.power.scripts(store.session.profileID) ?? [] } }
    private func save(_ script: UserScript) { perform { try store.services?.power.save(script, profile: store.session.profileID); refreshRuntime() } }
    private func refreshRuntime() {
        scripts = (try? store.services?.power.scripts(store.session.profileID)) ?? []
        // Update all windows for this profile, including Peek. Private services remain independent.
        let stores = store.application.map { Array($0.stores.values) } ?? [store]
        for target in stores where target.session.profileID == store.session.profileID && target.services === store.services {
            for page in Array(target.pages.values) + [target.peekPage].compactMap({ $0 }) {
                ScriptRuntime.install(scripts, controller: page.webView.configuration.userContentController)
            }
        }
    }
    private func perform(_ action: () throws -> Void) { do { try action(); error = nil } catch { self.error = error.localizedDescription } }
}

struct ScriptEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var script: UserScript
    var error: String?
    var save: (UserScript) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Script name", text: $script.name)
            Text("Match patterns — one domain or URL pattern per line; * matches any characters.").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $script.patterns).font(.system(.body, design: .monospaced)).frame(height: 60)
            HStack { Toggle("Enabled", isOn: $script.enabled); Spacer(); Picker("Run at", selection: $script.start) { Text("Document Start").tag(true); Text("Document End").tag(false) }.frame(width: 260) }
            TextEditor(text: $script.source).font(.system(.body, design: .monospaced)).border(.separator)
            if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") { save(script) }.keyboardShortcut(.defaultAction).disabled(script.name.isEmpty || script.patterns.isEmpty) }
        }.padding(20).frame(width: 620, height: 480)
    }
}

/// A fresh field is mounted each time Find opens; select only its own editor.
struct FindQueryField: NSViewRepresentable {
    let title: String
    @Binding var text: String
    let submit: () -> Void
    let close: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> FindTextField {
        let field = FindTextField()
        field.isBordered = false; field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = L10n.string(title)
        field.setAccessibilityLabel(L10n.string(title))
        field.font = .systemFont(ofSize: 13)
        field.stringValue = text; field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: FindTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FindQueryField
        init(_ parent: FindQueryField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { parent.text = field.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) { parent.submit(); return true }
            if selector == #selector(NSResponder.cancelOperation(_:)) { parent.close(); return true }
            return false
        }
    }
}
final class FindTextField: NSTextField {
    private var selectedOnOpen = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !selectedOnOpen else { return }
        selectedOnOpen = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
            self.selectText(nil)
        }
    }
}

struct PageFindBar: View {
    @Environment(\.profileAppearance) private var appearance
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Bindable var page: TabPage
    let close: () -> Void
    @State private var missing = false
    private var query: String { page.findQuery }
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary).padding(.leading, 4).accessibilityHidden(true)
            FindQueryField(title: "Find on page", text: $page.findQuery,
                           submit: { search(backward: false) }, close: close)
                .frame(minWidth: 60, maxWidth: .infinity).frame(height: 22)
            if missing { Text("No matches").font(.caption).foregroundStyle(.secondary).fixedSize() }
            Divider().frame(height: 16).padding(.horizontal, 2)
            control("Previous match", "chevron.up") { search(backward: true) }.disabled(query.isEmpty || missing)
            control("Next match", "chevron.down") { search(backward: false) }.disabled(query.isEmpty || missing)
            control("Close Find", "xmark", action: close)
        }
            .font(.system(size: 13)).foregroundStyle(.primary).tint(.primary)
            .buttonStyle(.plain).padding(.horizontal, 8).padding(.vertical, 6).frame(width: 310)
            .background { background }
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5).allowsHitTesting(false))
            .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
            .task(id: query) {
                do {
                    guard !Task.isCancelled else { return }
                    let count = try await WebPageFind.update(page.webView, query: query)
                    if !Task.isCancelled { missing = !query.isEmpty && count == 0 }
                } catch { }
            }
            .onDisappear { Task { _ = try? await WebPageFind.update(page.webView, query: "") } }
    }
    @ViewBuilder private var background: some View {
        if reduceTransparency { Capsule().fill(Color(nsColor: .windowBackgroundColor)) }
        else if #available(macOS 26, *), appearance.glass != "Reduced" {
            Color.clear.glassEffect(.regular, in: .capsule)
        } else { Capsule().fill(.regularMaterial) }
    }
    private func control(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 26, height: 26).contentShape(Circle())
        }.help(L10n.string(title)).accessibilityLabel(L10n.string(title))
    }
    private func search(backward: Bool) {
        guard !query.isEmpty else { return }
        Task {
            if let count = try? await WebPageFind.update(page.webView, query: query, step: backward ? -1 : 1) { missing = count == 0 }
        }
    }
}
