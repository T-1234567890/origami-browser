import SwiftUI

struct AIContextActions: View {
    let store: BrowserStore
    @State private var action: AIAction?
    var body: some View {
        Menu {
            ForEach(AIAction.allCases.filter { $0 != .web && $0 != .peek }) { item in Button(item.rawValue) { action = item } }
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
            TextField("Question or focus (optional)", text: $query)
            Text("Sends your question and the selected text or page excerpts to \(AISettings.shared.provider.rawValue). Web verification may also use the provider’s search service.").font(.caption).foregroundStyle(.secondary)
            if store.isPrivate { Text("Private: kept in memory by Origami; the provider still receives this request.").font(.caption).foregroundStyle(.secondary) }
            if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Continue", action: run).disabled(busy || action == .compare && !(2...6).contains(selected.count)) }
            if busy { ProgressView().controlSize(.small) }
        }.padding(22).frame(width: 440).onDisappear { pending?.cancel() }
    }
    private func run() {
        busy = true
        pending = Task {
            do {
                var contexts: [AIPageContext] = []
                if action == .compare {
                    for id in selected.sorted(by: { $0.uuidString < $1.uuidString }) { if let page = store.loadedPage(for: id) { contexts.append(try await AIController.context(page)) } }
                } else {
                    guard let page = store.visiblePage else { throw AIError.noPage }
                    contexts = [try await AIController.context(page, selection: [.selection, .explain, .verify].contains(action))]
                }
                let mode: AskMode = [.compare, .verify, .credibility, .primary, .original].contains(action) ? .research : .ask
                let question = query.trimmingCharacters(in: .whitespacesAndNewlines)
                let model = AISettings.shared.routedModel(action: action, mode: mode)
                guard !model.isEmpty else { throw AIError.model }
                guard AICredentialStore().contains(AISettings.shared.provider) else { throw AIError.credential }
                let maximum = 60000 / max(1, contexts.count)
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

struct PeekAIButton: View {
    let page: TabPage
    let isPrivate: Bool
    @State private var showing = false
    @State private var result = ""
    @State private var busy = false
    @State private var generation = UUID()
    var body: some View {
        Button { showing.toggle() } label: { Image(systemName: "text.magnifyingglass") }.help("Summarize with AI")
            .popover(isPresented: $showing) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Page Summary").font(.headline)
                    if result.isEmpty {
                        Text("Send this page excerpt to your configured provider for a short summary.").font(.caption).foregroundStyle(.secondary)
                        if isPrivate { Text("Your provider receives the request; Origami won’t save it.").font(.caption) }
                        Button("Summarize") { generation = UUID(); busy = true }
                    } else { Text(result).font(.system(size: 14, design: .serif)).textSelection(.enabled) }
                    if busy { ProgressView().controlSize(.small) }
                }.padding(16).frame(width: 280)
                    .task(id: generation) {
                        guard busy else { return }
                        let network = AINetwork(); defer { network.stop(); busy = false }
                        do {
                            let context = try await AIController.context(page)
                            let provider = AISettings.shared.provider
                            let input = AIRequest(query: "What is this page?", mode: .ask, action: .peek, contexts: [context], model: AISettings.shared.routedModel(action: .peek, mode: .ask))
                            let adapter = ProviderWire.adapter(provider)
                            let request = try adapter.request(input, credential: AICredentialStore().read(provider))
                            let output = try adapter.parse(await network.data(for: request)); try Task.checkCancellation()
                            result = String(output.text.prefix(700))
                        } catch { if !Task.isCancelled { result = (error as? AIError)?.localizedDescription ?? "Summary unavailable." } }
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
