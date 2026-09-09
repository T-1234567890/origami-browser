import SwiftUI

struct AIContextActions: View {
    let store: BrowserStore
    @State private var action: AIAction?
    var body: some View {
        Menu {
            ForEach(AIAction.allCases.filter { $0 != .web && $0 != .peek && ($0 != .credibility || AISettings.aiPeekAvailable) }) { item in Button(item.rawValue) { action = item } }
        } label: { Label("Ask / Research", systemImage: "text.magnifyingglass") }
            .menuIndicator(.hidden)
            .sheet(item: $action) { item in AIContextSheet(store: store, action: item) }
    }
}
struct AIContextSheet: View {
    let store: BrowserStore
    let action: AIAction
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected = Set<UUID>()
    @State private var error: String?
    @State private var busy = false
    @State private var pending: Task<Void, Never>?
    private var candidates: [BrowserTab] { store.session.tabs.filter { store.loadedPage(for: $0.id)?.nativePage == nil && store.loadedPage(for: $0.id) != nil && $0.url?.scheme?.hasPrefix("http") == true } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(action.rawValue).font(.headline)
            if action == .compare {
                Text("Choose 2–6 loaded tabs.").font(.caption).foregroundStyle(.secondary)
                ScrollView { ForEach(candidates) { tab in Toggle(tab.title, isOn: Binding(get: { selected.contains(tab.id) }, set: { if $0 { selected.insert(tab.id) } else { selected.remove(tab.id) } })) } }.frame(maxHeight: 180)
            } else { Text(store.visiblePage?.pageTitle ?? "Current page").lineLimit(2) }
            if action != .credibility {
            TextField("Question or focus (optional)", text: $query)
            Text("Sends your question and the selected text or page excerpts to \(AISettings.shared.provider.rawValue). Web verification may also use the provider’s search service.").font(.caption).foregroundStyle(.secondary)
            }
            if store.isPrivate { Text("Private: kept in memory by Origami; the provider still receives this request.").font(.caption).foregroundStyle(.secondary) }
            if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer(); Button("Cancel") { dismiss() }
                if action != .credibility { Button("Continue", action: run).disabled(busy || action == .compare && !(2...6).contains(selected.count)) }
                else if error != nil { Button("Retry", action: run).disabled(busy) }
            }
            if busy { ProgressView().controlSize(.small) }
        }.padding(22).frame(width: 440)
            .task { if action == .credibility && pending == nil { run() } }
            .onDisappear { pending?.cancel() }
    }
    private func run() {
        busy = true; error = nil
        pending = Task {
            do {
                var contexts: [AIPageContext] = []
                if action == .compare {
                    for id in selected.sorted(by: { $0.uuidString < $1.uuidString }) { if let page = store.loadedPage(for: id) { contexts.append(try await AIController.context(page)) } }
                } else {
                    guard let page = store.visiblePage else { throw AIError.noPage }
                    contexts = [try await AIController.context(page, selection: [.selection, .explain, .verify].contains(action))]
                }
                let mode: AskMode = [.compare, .verify, .primary, .original].contains(action) ? .research : .ask
                let question = query.trimmingCharacters(in: .whitespacesAndNewlines)
                let model = AISettings.shared.routedModel(action: action, mode: mode)
                guard !model.isEmpty else { throw AIError.model }
                guard AICredentialStore().contains(AISettings.shared.provider) else { throw AIError.credential }
                let maximum = action == .credibility ? 8000 : 60000 / max(1, contexts.count)
                contexts = contexts.map { AIPageContext(title: $0.title, url: $0.url, text: String($0.text.prefix(maximum))) }
                try Task.checkCancellation()
                if let app = store.application, app.stores[store.session.windowID] !== store { throw AIError.cancelled }
                let id = store.newTab()
                store.services?.ai.start(AIRequest(query: question.isEmpty ? action.rawValue + ": " + contexts.map(\.title).joined(separator: ", ") : String(question.prefix(12000)), mode: mode, action: action, contexts: contexts, model: model), tab: id, profile: store.session.profileID)
                dismiss()
            } catch { self.error = (error as? AIError)?.localizedDescription ?? "Could not read the selected page content." }
            busy = false
        }
    }
}

struct PeekAIResults: View {
    let store: BrowserStore
    let page: TabPage
    @Bindable private var settings = AISettings.shared
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if page.isLoading { ProgressView().controlSize(.small) }
                else if settings.aiPeekEnabled {
                    if settings.aiPeekSummary { PeekAIAssessment(store: store, page: page, action: .peek) }
                    if settings.aiPeekCredibility { PeekAIAssessment(store: store, page: page, action: .credibility) }
                }
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
        }.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct PeekAIAssessment: View {
    let store: BrowserStore
    let page: TabPage
    let action: AIAction
    @State private var event: AISearchEvent?
    @State private var error: String?
    @State private var attempt = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(action == .peek ? "Page Summary" : "Credibility").font(.caption.bold())
            if let event {
                if action == .credibility {
                    Text(event.credibility?.rawValue ?? CredibilityState.unknown.rawValue).font(.subheadline.bold())
                    Text("AI-assisted assessment, not a verdict on every claim.").font(.caption2).foregroundStyle(.secondary)
                }
                Text(event.answerV1?.summary ?? "").font(.caption).textSelection(.enabled)
                ForEach(event.answerV1?.sources ?? [], id: \.id) { source in
                    if let url = AISource.safeURL(source.url) {
                        Button { store.newTab(url: url) } label: { Label(source.title, systemImage: "arrow.up.right") }
                            .buttonStyle(.plain).font(.caption).foregroundStyle(Personalization.shared.accent)
                    }
                }
            } else if let error {
                Text(error).font(.caption).foregroundStyle(.secondary)
                Button("Retry") { attempt += 1 }
            } else { ProgressView().controlSize(.small) }
        }
        .task(id: attempt) {
            event = nil; error = nil
            do {
                let extracted = try await AIController.context(page)
                let context = AIPageContext(title: extracted.title, url: extracted.url, text: String(extracted.text.prefix(8000)))
                let settings = AISettings.shared
                let mode: AskMode = .ask
                let provider = settings.provider
                var input = AIRequest(query: action == .peek ? "Briefly summarize this page." : "Evaluate this page's credibility using web evidence.", mode: mode, action: action, contexts: [context], model: settings.routedModel(action: action, mode: mode))
                input.isPrivate = store.isPrivate
                input.generatedVisuals = false
                let result = try await FallbackAIClient(base: NativeAIClient(), settings: settings).answer(provider: provider, input: input)
                try Task.checkCancellation()
                var answer = AISearchEvent(query: input.query, mode: mode, action: action, provider: provider, model: input.model)
                try AnswerProtocol.apply(result, to: &answer, input: input)
                event = answer
            } catch {
                if !Task.isCancelled { self.error = (error as? AIError)?.localizedDescription ?? "Assessment unavailable." }
            }
        }
    }
}

struct AISearchHistory: View {
    let store: BrowserStore
    @State private var events: [AISearchEvent] = []
    @State private var selected = Set<UUID>()
    @State private var selecting = false
    @State private var confirmingDelete = false
    var body: some View {
        if !store.isPrivate {
            VStack(alignment: .leading, spacing: 10) {
                if !events.isEmpty {
                    HStack {
                        Text("Search & Research").font(.headline); Spacer()
                        if selecting { Button("Cancel") { selecting = false; selected = [] }.buttonStyle(.plain) }
                        Button { if selecting { confirmingDelete = true } else { selecting = true } } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain).disabled(selecting && selected.isEmpty).help(selecting ? "Delete selected" : "Select history to delete")
                    }
                }
                ForEach(events) { event in
                    HStack {
                        if selecting {
                            Toggle("Select exploration", isOn: Binding(get: { selected.contains(event.id) }, set: { if $0 { selected.insert(event.id) } else { selected.remove(event.id) } })).labelsHidden().toggleStyle(.checkbox)
                        }
                        Button(event.query) {
                            if selecting { if !selected.insert(event.id).inserted { selected.remove(event.id) }; return }
                            let id = store.newTab()
                            store.services?.ai.events[id] = event
                            do { try store.services?.ai.repository.save(event, profile: store.session.profileID, tab: id) } catch { store.persistenceError = "Could not restore the saved answer." }
                        }.buttonStyle(.plain)
                        Spacer(); Text(event.date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.task { reload() }
                .onReceive(NotificationCenter.default.publisher(for: .origamiHistoryChanged)) { _ in reload() }
                .alert("Delete \(selected.count) selected explorations?", isPresented: $confirmingDelete) {
                    Button("Cancel", role: .cancel) { }
                    Button("Delete", role: .destructive) {
                        do { try store.services?.ai.deleteHistory(selected, profile: store.session.profileID); selecting = false; selected = []; reload() }
                        catch { store.persistenceError = "Could not delete the selected history." }
                    }
                } message: { Text("Their prompts, answers, references, visuals, and versions will be permanently deleted. This cannot be undone.") }
        }
    }
    private func reload() { events = (try? store.services?.ai.repository.list(profile: store.session.profileID)) ?? []; selected.formIntersection(Set(events.map(\.id))) }
}
