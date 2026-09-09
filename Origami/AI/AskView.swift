import SwiftUI
import WebKit
import MarkdownUI

struct AskSurface: View {
    let store: BrowserStore
    let tabID: UUID
    let returnToSearch: () -> Void
    @State private var copiedID: UUID?
    @State private var followUp = ""
    private var selectedModel: String {
        get { store.loadedPage(for: tabID)?.askModelSelections[AISettings.shared.provider] ?? "" }
        nonmutating set { store.loadedPage(for: tabID)?.askModelSelections[AISettings.shared.provider] = newValue }
    }
    @State private var selectedMode = AskMode.ask
    private var backgroundColor: Color { scheme == .dark ? Color(red: 0.115, green: 0.11, blue: 0.10) : Color(red: 0.985, green: 0.975, blue: 0.955) }
    @Environment(\.colorScheme) private var scheme
    private var controller: AIController? { store.services?.ai }
    private var event: AISearchEvent? { controller?.events[tabID] }
    private var loading: Bool { event?.status == "Requesting answer" || event?.explorations?.last?.status == "Requesting answer" }
    var body: some View {
        ScrollViewReader { reader in
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let root = event {
                  ForEach([root] + (root.explorations ?? [])) { event in
                    if event.id != root.id {
                        Divider()
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(event.query).font(.system(size: 19, weight: .medium, design: .serif)).foregroundStyle(Personalization.shared.accent).textSelection(.enabled)
                            FollowUpVersionControl(event: event, store: store, tabID: tabID, model: selectedModel.isEmpty ? event.model : selectedModel).disabled(loading)
                        }
                    }
                    if event.status == "Requesting answer" { BreathingCircle() }
                    else if event.status != "Complete" {
                        HStack {
                            Text(event.status).font(.caption).foregroundStyle(.secondary)
                            if !loading && controller?.canRetry(event.id, tab: tabID) == true {
                                Button { controller?.retry(event.id, tab: tabID, profile: store.session.profileID) } label: { Label("Retry", systemImage: "arrow.clockwise") }.buttonStyle(.plain)
                            }
                        }
                    }
                    if let state = event.credibility { Label(state.rawValue, systemImage: state == .highlyCredible || state == .credible ? "checkmark.circle" : state == .unknown ? "questionmark.circle" : "exclamationmark.circle").font(.headline); Text("AI-assisted source assessment, not a verdict on every claim.").font(.caption).foregroundStyle(.secondary) }
                    if let state = event.verification { Text(state.rawValue).font(.headline); Text("AI-assisted assessment. Review the linked evidence before relying on it.").font(.caption).foregroundStyle(.secondary) }
                    if let answer = event.answerV1 {
                        StructuredAnswerView(answer: answer, store: store, visualsAllowed: event.generatedVisuals == true, referencePrefix: event.id.uuidString) { id in
                            Task { @MainActor in
                                await Task.yield()
                                withAnimation(.easeInOut(duration: 0.25)) { reader.scrollTo(id, anchor: .center) }
                            }
                        }
                    } else if let markdown = event.markdown {
                        ForEach(event.blocks.filter { $0.kind == .callout && !markdown.contains($0.text) }) { block in
                            AnswerBlockView(block: block, event: event, store: store)
                        }
                        AskMarkdown(text: markdown, store: store)
                    } else {
                        ForEach(event.blocks) { block in AnswerBlockView(block: block, event: event, store: store) }
                    }
                    if let suggestions = event.searchSuggestions, !suggestions.isEmpty {
                        GoogleSearchAttribution(html: suggestions, store: store)
                    }
                    if !event.sources.isEmpty {
                        Divider(); Text("Sources").font(.system(size: 22, weight: .medium, design: .serif))
                        ForEach(Array(event.sources.enumerated()), id: \.element.id) { index, source in
                            HStack(alignment: .top) {
                                Text("\(index + 1)").font(.caption).foregroundStyle(.secondary).frame(width: 20)
                                Button { open(source, peek: false) } label: {
                                    VStack(alignment: .leading, spacing: 3) { Text(source.title); Text(source.provenance + " · " + (URL(string: source.url)?.host ?? "")).font(.caption).foregroundStyle(.secondary) }
                                }.buttonStyle(.plain)
                                Spacer(); Button { open(source, peek: false) } label: { Image(systemName: "arrow.up.right") }.help("Visit reference in a new tab")
                            }
                        }
                    }
                    if event.status == "Complete" {
                    if let disclosure = event.fallbackDisclosure { Text(disclosure).font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        Button { copyText((event.answerV1?.plainText ?? event.markdown ?? event.blocks.map(\.text).joined(separator: "\n\n")) + "\n\nSources:\n" + (event.answerV1?.sources.map { $0.title + " — " + $0.url } ?? event.sources.map { $0.title + " — " + $0.url }).joined(separator: "\n")); copiedID = event.id } label: { Image(systemName: copiedID == event.id ? "checkmark" : "doc.on.doc") }.buttonStyle(.plain).help("Copy response")
                        Spacer(); if let usage = event.usage { Text(usage).font(.caption).foregroundStyle(.secondary) }
                    }
                    }
                  }
                }
            }.textSelection(.enabled).frame(maxWidth: 760, alignment: .leading).padding(32).padding(.bottom, 80).frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                Button(action: returnToSearch) { Image(systemName: "xmark").frame(width: 28, height: 28) }
                    .buttonStyle(.plain).modifier(ChromeSurface()).accessibilityLabel("Return to Ask the Web")
                Text(event?.query ?? "Ask the Web").font(.system(size: 24, weight: .medium, design: .serif))
                    .lineLimit(2).minimumScaleFactor(0.65).truncationMode(.tail).textSelection(.enabled)
                Spacer(minLength: 0)
                if store.isPrivate { Image(systemName: "lock").accessibilityLabel("Private") }
            }.frame(maxWidth: 760, alignment: .leading).padding(.horizontal, 32).padding(.vertical, 16)
                .frame(maxWidth: .infinity).background(backgroundColor)
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [backgroundColor, backgroundColor.opacity(0)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 24).offset(y: 24).allowsHitTesting(false)
                }
        }
        .overlay(alignment: .bottom) {
            if let root = event, loading || (root.status == "Complete" && (root.explorations?.count ?? 0) < 20) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("Explore a follow-up…", text: $followUp).textFieldStyle(.plain).onSubmit(sendFollowUp)
                        AskComposerOptions(model: Binding(get: { selectedModel }, set: { selectedModel = $0 }), mode: $selectedMode)
                        Button { if loading { controller?.cancel(tabID) } else { sendFollowUp() } } label: {
                            Image(systemName: loading ? "stop.fill" : "arrow.up").frame(width: 28, height: 28)
                        }.buttonStyle(.plain).disabled(!loading && followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityLabel(loading ? "Cancel response" : "Send follow-up")
                    }
                }.padding(12).modifier(ChromeSurface())
                    .frame(maxWidth: 760).padding(.horizontal, 32).padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
            }
        }
        .background(scheme == .dark ? Color(red: 0.115, green: 0.11, blue: 0.10) : Color(red: 0.985, green: 0.975, blue: 0.955))
        .task { controller?.restore(tab: tabID, profile: store.session.profileID); selectedMode = event?.mode ?? .ask }
        .task(id: copiedID) { if copiedID != nil { try? await Task.sleep(for: .seconds(2)); guard !Task.isCancelled else { return }; copiedID = nil } }
        }
    }
    private func sendFollowUp() {
        guard !loading, let event, (event.explorations?.count ?? 0) < 20, event.explorations?.last?.status != "Requesting answer" else { return }
        let question = followUp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        guard AISettings.shared.setupComplete, AICredentialStore().contains(AISettings.shared.provider) else { store.showingAISetup = true; return }
        controller?.followUp(question, tab: tabID, profile: store.session.profileID, model: selectedModel.isEmpty ? AISettings.shared.routedModel(action: .web, mode: selectedMode) : selectedModel, mode: selectedMode)
        followUp = ""
    }
    private func open(_ source: AISource, peek: Bool) { guard let url = AISource.safeURL(source.url) else { return }; if peek { store.openPeek(url) } else { store.newTab(url: url) } }
}

private struct AnswerBlockView: View {
    let block: AIBlock
    let event: AISearchEvent
    let store: BrowserStore
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if block.kind == .table {
                ScrollView(.horizontal) {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                        ForEach(Array(block.rows.enumerated()), id: \.offset) { index, row in
                            GridRow { ForEach(Array(row.enumerated()), id: \.offset) { _, cell in Text(cell).font(.system(size: 15, weight: index == 0 ? .semibold : .regular, design: .serif)).frame(maxWidth: 230, alignment: .leading) } }
                        }
                    }
                }
            } else {
                Text(block.kind == .heading ? block.text.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) : block.text)
                    .font(.system(size: block.kind == .heading ? 23 : block.kind == .code ? 13 : 17, weight: block.kind == .heading ? .semibold : .regular, design: block.kind == .code ? .monospaced : .serif))
                    .lineSpacing(6).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(block.kind == .callout ? 10 : 0)
                    .background(block.kind == .callout ? Color.primary.opacity(0.04) : .clear, in: RoundedRectangle(cornerRadius: 4))
            }
            if !block.sourceURLs.isEmpty {
                HStack {
                    ForEach(block.sourceURLs, id: \.self) { url in
                        if let index = event.sources.firstIndex(where: { $0.url == url }) {
                            Button("[\(index + 1)]") { if let url = AISource.safeURL(url) { store.newTab(url: url) } }.buttonStyle(.plain).font(.caption).foregroundStyle(Personalization.shared.accent).help(event.sources[index].title)
                        }
                    }
                }.accessibilityLabel("Supporting sources")
            }
        }
    }
}

// Google's required search attribution is isolated from the native answer renderer and all browser services.
private struct GoogleSearchAttribution: View {
    let html: String
    let store: BrowserStore
    @State private var height: CGFloat = 0
    var body: some View { GoogleAttributionHost(html: html, store: store, height: $height).frame(height: height).clipped().accessibilityHidden(height == 0) }
}
struct GoogleAttributionHost: NSViewRepresentable {
    let html: String
    let store: BrowserStore
    @Binding var height: CGFloat
    func makeCoordinator() -> Coordinator { Coordinator(store: store, height: $height) }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config); view.navigationDelegate = context.coordinator
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.html != html else { return }; context.coordinator.html = html
        context.coordinator.height.wrappedValue = 0
        context.coordinator.failed = false
        let generation = UUID(); context.coordinator.generation = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak coordinator = context.coordinator] in
            guard let coordinator, coordinator.generation == generation, coordinator.height.wrappedValue == 0 else { return }; coordinator.failed = true
        }
        view.loadHTMLString("<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'; img-src data:; script-src 'none'; form-action 'none'; base-uri 'none'\">" + String(html.prefix(100000)), baseURL: nil)
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var html = ""
        weak var store: BrowserStore?
        var height: Binding<CGFloat>
        var failed = false
        var generation = UUID()
        init(store: BrowserStore, height: Binding<CGFloat>) { self.store = store; self.height = height }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("document.body.innerText.trim() || document.querySelector('a') ? Math.min(160,document.body.scrollHeight) : 0") { [weak self] value, error in
                guard let self, !failed else { return }; height.wrappedValue = error == nil ? CGFloat(value as? Double ?? 0) : 0
            }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed = true; height.wrappedValue = 0 }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed = true; height.wrappedValue = 0 }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failed = true; height.wrappedValue = 0 }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let raw = action.request.url?.absoluteString, let url = AISource.safeURL(raw) { store?.newTab(url: url); decisionHandler(.cancel) }
            else { decisionHandler(action.request.url?.scheme == "about" ? .allow : .cancel) }
        }
    }
}

private struct FollowUpVersionControl: View {
    let event: AISearchEvent
    let store: BrowserStore
    let tabID: UUID
    let model: String
    @State private var showing = false
    @State private var editing = false
    @State private var draft = ""
    @State private var error = ""
    var body: some View {
        Button { editing = false; draft = event.query; showing = true } label: {
            Image(systemName: "pencil").font(.system(size: 16, weight: .medium))
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Edit prompt and versions")
            .popover(isPresented: $showing) {
                VStack(alignment: .leading, spacing: 12) {
                    if editing {
                        Text("Edit follow-up").font(.headline)
                        TextEditor(text: $draft).font(.body).frame(height: 100)
                        HStack {
                            Button("Cancel") { editing = false }
                            Spacer()
                            Button("Submit") {
                                store.services?.ai.editFollowUp(event.id, query: draft, tab: tabID, profile: store.session.profileID, model: model)
                                showing = false
                            }.disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft == event.query)
                        }
                    } else {
                        Button { editing = true } label: { Label("Edit prompt", systemImage: "pencil") }.buttonStyle(.plain)
                            .disabled((event.versions?.count ?? 0) >= 19)
                        Divider()
                        Text("Versions").font(.headline)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(((event.versions ?? []) + [event]).sorted { $0.date < $1.date }) { version in
                                    Button {
                                        guard version.id != event.id else { return }
                                        do {
                                            try store.services?.ai.selectVersion(version.id, followUp: event.id, tab: tabID, profile: store.session.profileID)
                                            showing = false
                                        } catch { self.error = "Couldn’t save the selected version." }
                                    } label: {
                                        HStack {
                                            Text(version.query).lineLimit(2)
                                            Spacer()
                                            if version.id == event.id { Image(systemName: "checkmark") }
                                        }.contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                }
                            }
                        }.frame(maxHeight: 220)
                    }
                    if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.secondary) }
                }.padding(16).frame(width: 310)
            }
    }
}
