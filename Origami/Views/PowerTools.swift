import UniformTypeIdentifiers
import SwiftUI
import WebKit

struct QuickTools: View {
    let store: BrowserStore
    var close: () -> Void
    @State private var scripts = false
    @State private var credibility = false
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
                        command("Find", "magnifyingglass") { close(); store.showingFind = true }
                        command("Print", "printer") { page?.webView.printOperation(with: .shared).run() }
                        command("Save PDF…", "square.and.arrow.down") { savePDF() }
                        command("Cite Page", "quote.opening") { cite(false) }
                        command("Cite Selection", "text.quote") { cite(true) }
                    }.disabled(page?.nativePage != nil || page == nil)
                    section("RSS") {
                        command("RSS Feeds", "dot.radiowaves.left.and.right") { close(); store.openInternal(.feeds) }
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
                        command("Manage Scripts…", "slider.horizontal.3") { scripts = true }
                    }
                    section("Citations") {
                        if AISettings.aiPeekAvailable {
                        command("Evaluate Credibility", "checkmark.shield") { credibility = true }
                            .disabled(page?.nativePage != nil || page == nil)
                        }
                        command("Saved References…", "books.vertical") { close(); store.openInternal(.references) }
                    }
                    if let error { Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(16).frame(width: 290, height: 480)
            .task(id: page?.currentURL) { await page?.discoverFeeds() }
            .sheet(isPresented: $credibility) { AIContextSheet(store: store, action: .credibility) }
            .sheet(isPresented: $scripts) { ScriptManager(store: store) }
            .sheet(isPresented: Binding(get: { output != nil }, set: { if !$0 { output = nil } })) {
                VStack(alignment: .leading) {
                    Text("Script Result").font(.headline)
                    ScrollView { Text(output ?? "").font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    HStack { Spacer(); Button("Copy") { copyText(output ?? "") }; Button("Done") { output = nil } }
                }.padding(20).frame(width: 540, height: 380)
            }
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) { Text(title).font(.caption).foregroundStyle(.secondary); content() }.padding(.bottom, 10)
    }
    private func command(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain).padding(.vertical, 3)
    }
    private func cite(_ selection: Bool) {
        guard let page else { return }
        Task { do { let draft = try await PageCitation.extract(page, selection: selection); close(); store.citationDraft = draft; error = nil } catch { self.error = error.localizedDescription } }
    }
    private func run(_ script: UserScript) {
        guard let page else { return }
        Task { do { output = String(try await ScriptRuntime.run(script, page: page).prefix(200000)); error = nil } catch { self.error = error.localizedDescription } }
    }
    private func savePDF() {
        guard let page else { return }
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
    @Environment(\.dismiss) private var dismiss
    @State private var scripts: [UserScript] = []
    @State private var draft: UserScript?
    @State private var error: String?
    @State private var result: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Scripts").font(.title2); Spacer(); Button("New Script") { draft = UserScript() }; Button("Done") { dismiss() } }
            Text("Scripts can read and change matching pages. Only enable code you trust. Changes apply on the next navigation.").font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(scripts) { script in
                    HStack {
                        Toggle(script.name, isOn: Binding(get: { script.enabled }, set: { enabled in var changed = script; changed.enabled = enabled; save(changed) }))
                        Spacer(); Button("Edit") { draft = script }
                        Button("Run") { guard let page = store.visiblePage else { return }; Task { do { result = String(try await ScriptRuntime.run(script, page: page).prefix(200000)) } catch { self.error = error.localizedDescription } } }
                        Button("Delete", role: .destructive) { perform { try store.services?.power.remove(script, profile: store.session.profileID); refreshRuntime() } }
                    }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
            if let result { ScrollView { Text(result).textSelection(.enabled) }.frame(maxHeight: 100); Button("Copy Result") { copyText(result) } }
        }.padding(20).frame(width: 660, height: 460).task { load() }
            .sheet(item: $draft) { script in ScriptEditor(script: script, error: error) { save($0); if error == nil { draft = nil } } }
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
    @State var script: UserScript
    var error: String?
    var save: (UserScript) -> Void
    @Environment(\.dismiss) private var dismiss
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

struct CitationPanel: View {
    let store: BrowserStore
    @State var citation: PageCitation
    var onClose: (() -> Void)? = nil
    @State private var preview = ""
    @State private var editing = false
    @State private var format = "APA"
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Cite Page").font(.headline); Spacer()
                Button(editing ? "Review" : "Edit") { editing.toggle() }
            }
            Picker("Format", selection: $format) { ForEach(PageCitation.formats, id: \.self) { Text(PageCitation.formatLabel($0)).tag($0) } }
            ScrollView { Text(preview.isEmpty ? "Formatting citation…" : preview).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(height: 100).clipped()
            ScrollView {
            if editing {
            Form {
                TextField("Title", text: $citation.title)
                TextField("Author(s)", text: $citation.author)
                TextField("Publisher", text: $citation.publisher)
                TextField("Published", text: $citation.published)
                TextField("Updated", text: $citation.updated)
                TextField("URL", text: $citation.url)
                TextField("DOI", text: $citation.doi)
                TextField("Accessed", text: $citation.accessed)
                if !citation.quotation.isEmpty { TextField("Quotation", text: $citation.quotation, axis: .vertical).lineLimit(2...4) }
            }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array([( "Title", citation.title), ("Author(s)", citation.author), ("Publisher", citation.publisher), ("Published", citation.published), ("Updated", citation.updated), ("URL", citation.url), ("DOI", citation.doi), ("Accessed", citation.accessed), ("Quotation", citation.quotation)].enumerated()), id: \.offset) { _, item in
                        if !item.1.isEmpty { LabeledContent(item.0) { Text(item.1).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) } }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            Link("CSL formatting · citeproc-js © Frank Bennett", destination: URL(string: "https://github.com/Juris-M/citeproc-js")!).font(.caption).foregroundStyle(.secondary)
            if let message { Text(message).font(.caption) }
            HStack { Button("Copy Citation") { copyText(preview) }.disabled(preview.isEmpty); Button("Add to References") { do { try store.services?.power.add(citation, profile: store.session.profileID); finish() } catch { message = error.localizedDescription } }; Spacer(); Button("Done") { finish() } }
        }.padding(20).frame(width: 570, height: 550).background(Color(nsColor: .windowBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 14))
        .task(id: ((try? JSONEncoder().encode(citation).base64EncodedString()) ?? "") + format) { await updatePreview() }
        .onExitCommand { finish() }
    }
    private func finish() { if let onClose { onClose() } else { dismiss() } }
    private func updatePreview() async {
        preview = ""
        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        let value = await CitationFormattingWorker.shared.format(citation, style: format)
        guard !Task.isCancelled else { return }
        preview = value
    }

}

struct ReferenceCollection: View {
    let store: BrowserStore
    @State private var citations: [PageCitation] = []
    @State private var format = "BibTeX"
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading) {
            HStack { Text("References").font(.title2); Spacer() }
            Picker("Export format", selection: $format) { ForEach(PageCitation.exportFormats, id: \.self) { Text(PageCitation.formatLabel($0)).tag($0) } }
            List(citations) { item in
                HStack { VStack(alignment: .leading) { Text(item.title); Text(item.url).font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Copy") { Task { copyText(await CitationFormattingWorker.shared.format(item, style: format)) } }; Button("Remove", role: .destructive) { do { try store.services?.power.removeCitation(item.id, profile: store.session.profileID); load() } catch { self.error = error.localizedDescription } } }
            }
            if let error { Text(error).font(.caption) }
            HStack { Spacer(); Button("Copy All") { Task { copyText(await collectionText()) } }; Button("Export…", action: export).disabled(citations.isEmpty) }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .textBackgroundColor)).task { load() }
    }
    private func collectionText() async -> String {
        let items = citations; let style = format
        var output: [String] = []
        for item in items { output.append(await CitationFormattingWorker.shared.format(item, style: style)) }
        return output.joined(separator: "\n\n")
    }
    private func load() { do { citations = try store.services?.power.references(store.session.profileID) ?? [] } catch { self.error = error.localizedDescription } }
    private func export() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "References." + (format == "BibTeX" ? "bib" : format == "RIS" ? "ris" : format == "Markdown" ? "md" : "txt")
        panel.begin { result in guard result == .OK, let url = panel.url else { return }; let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }; Task { let output = await collectionText(); let writing = url.startAccessingSecurityScopedResource(); defer { if writing { url.stopAccessingSecurityScopedResource() } }; do { try output.write(to: url, atomically: true, encoding: .utf8) } catch { self.error = error.localizedDescription } } }
    }
}

struct PageFindBar: View {
    let page: TabPage
    let close: () -> Void
    @State private var query = ""
    @State private var missing = false
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 8) {
            TextField("Find on page", text: $query).textFieldStyle(.plain).focused($focused)
                .onSubmit { search(backward: false) }.onExitCommand(perform: close)
            if missing { Text("No matches").font(.caption).foregroundStyle(.secondary) }
            Button { search(backward: true) } label: { Image(systemName: "chevron.up") }.help("Previous match").disabled(query.isEmpty)
            Button { search(backward: false) } label: { Image(systemName: "chevron.down") }.help("Next match").disabled(query.isEmpty)
            Button(action: close) { Image(systemName: "xmark") }.help("Close Find")
        }.buttonStyle(.plain).padding(12).frame(width: 340)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10)).shadow(radius: 4)
            .onAppear { focused = true }
            .task(id: query) {
                guard !query.isEmpty else { missing = false; return }
                do {
                    try await Task.sleep(for: .milliseconds(100))
                    let result = try await page.webView.find(query, configuration: WKFindConfiguration())
                    if !Task.isCancelled { missing = !result.matchFound }
                } catch { }
            }
    }
    private func search(backward: Bool) {
        guard !query.isEmpty else { return }
        let config = WKFindConfiguration(); config.backwards = backward; config.wraps = true
        Task { if let result = try? await page.webView.find(query, configuration: config) { missing = !result.matchFound } }
    }
}
