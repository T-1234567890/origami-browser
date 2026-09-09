import SwiftUI

struct AskModelControl: View {
    @Binding var selection: String
    var mode: AskMode = .ask
    var body: some View {
        ModelSearchControl(selection: $selection, placeholder: AISettings.shared.displayName(AISettings.shared.routedModel(action: .web, mode: mode)), allowsDefault: true, leadingIcon: "cpu")
    }
}

struct ModelSearchControl: View {
    @Binding var selection: String
    var placeholder = "Search models…"
    var allowsDefault = false
    var clearLabel = "Use configured default"
    var leadingIcon: String? = nil
    var settingsStyle = false
    @State private var showing = false
    var body: some View {
        Button { showing = true } label: {
            if settingsStyle {
                AISettingsSelectionLabel(title: selection.isEmpty ? placeholder : AISettings.shared.displayName(selection))
            } else {
            HStack(spacing: 6) {
                if let leadingIcon { Image(systemName: leadingIcon).accessibilityHidden(true) }
                Text(selection.isEmpty ? (placeholder.isEmpty ? "Choose model" : placeholder) : AISettings.shared.displayName(selection)).lineLimit(1)
            }.font(.caption).foregroundStyle(Color.secondary)
            }
        }.buttonStyle(.plain).help("Search models")
            .popover(isPresented: $showing) {
                ModelSearchList(selection: $selection, allowsDefault: allowsDefault, clearLabel: clearLabel)
            }
    }
}
private struct ModelSearchList: View {
    var didSelect: (() -> Void)? = nil
    @Binding var selection: String
    var allowsDefault: Bool
    var clearLabel = "Use configured default"
    @Bindable private var settings = AISettings.shared
    @State private var query = ""
    @State private var error = ""
    @Environment(\.dismiss) private var dismiss
    private func finish() { if let didSelect { didSelect() } else { dismiss() } }
    private var choices: [String] {
        settings.availableModels.filter {
            (query.isEmpty || settings.displayName($0).localizedCaseInsensitiveContains(query) || $0.localizedCaseInsensitiveContains(query))
        }
    }
    var body: some View {
        let choices = choices
        VStack(alignment: .leading, spacing: 12) {
            TextField("Search models…", text: $query).textFieldStyle(.roundedBorder)
            if settings.provider == .openRouter {
                Text("Web search is billed separately, including for free models.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if allowsDefault && query.isEmpty { Button(clearLabel) { selection = ""; finish() }.buttonStyle(.plain).padding(.vertical, 8) }
                    ForEach(choices, id: \.self) { id in
                        Button { selection = id; finish() } label: {
                            HStack { Text(settings.displayName(id)).lineLimit(2); Spacer(); if selection == id { Image(systemName: "checkmark") } }
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if choices.isEmpty { Text("No matching models").foregroundStyle(.secondary).padding(.vertical, 12) }
                }
            }
        }.padding(16).frame(width: 330, height: 350)
            .task { if settings.provider == .openRouter { do { try await settings.refreshOpenRouterCatalog() } catch { self.error = "Couldn’t refresh models. Showing saved results." } } }
    }
}

struct AskModeControl: View {
    @Bindable private var settings = AISettings.shared
    @Binding var mode: AskMode
    @State private var showing = false
    var body: some View {
        Button { showing = true } label: { Label(mode.rawValue, systemImage: "slider.horizontal.3").font(.caption) }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .popover(isPresented: $showing) {
                VStack(spacing: 14) {
                    Text(mode.rawValue).font(.headline)
                    Slider(value: Binding(get: { Double(AskMode.allCases.firstIndex(of: mode) ?? 0) }, set: { mode = AskMode.allCases[Int($0.rounded())] }), in: 0...2, step: 1).tint(Personalization.shared.accent)
                        .accessibilityLabel("Answer mode").accessibilityValue(mode.rawValue)
                    HStack { ForEach(AskMode.allCases, id: \.self) { value in Button(value.rawValue) { mode = value }.buttonStyle(.plain).font(.caption).frame(maxWidth: .infinity) } }
                    Divider()
                    Toggle("Generated Visuals", isOn: $settings.generatedVisuals).toggleStyle(.switch).controlSize(.small)
                }.padding(18).frame(width: 260)
            }
    }
}

struct AskTimeline: View {
    let store: BrowserStore
    let tabID: UUID
    @State private var events: [AISearchEvent] = []
    @State private var selecting = false
    @State private var selected = Set<UUID>()
    @State private var confirmingDelete = false
    @State private var historyError = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Your explorations").font(.system(size: 22, weight: .medium, design: .serif))
                Spacer()
                if selecting { Button("Cancel") { selecting = false; selected = [] }.buttonStyle(.plain).font(.caption) }
                if !events.isEmpty {
                    Button { if selecting { confirmingDelete = true } else { selecting = true } } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).disabled(selecting && selected.isEmpty).help(selecting ? "Delete selected" : "Select history to delete")
                }
            }
            if selecting { Text("\(selected.count) selected").font(.caption).foregroundStyle(.secondary) }
            if !historyError.isEmpty { Text(historyError).font(.caption).foregroundStyle(.secondary) }
            if events.isEmpty { Text(store.isPrivate ? "Private explorations aren’t saved to history." : "Your questions will appear here.").foregroundStyle(.secondary) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(events) { event in
                        HStack(alignment: .top, spacing: 14) {
                            if selecting {
                                Toggle("Select exploration", isOn: Binding(get: { selected.contains(event.id) }, set: { if $0 { selected.insert(event.id) } else { selected.remove(event.id) } })).labelsHidden().toggleStyle(.checkbox)
                            } else {
                                VStack(spacing: 0) { Circle().fill(Personalization.shared.accent).frame(width: 7, height: 7); Rectangle().fill(.separator).frame(width: 1).frame(maxHeight: .infinity) }.frame(width: 12)
                            }
                            Button {
                                if selecting { if !selected.insert(event.id).inserted { selected.remove(event.id) }; return }
                                store.loadedPage(for: tabID)?.answerFromHistory = true
                                store.services?.ai.events[tabID] = event
                                if !store.isPrivate { try? store.services?.ai.repository.save(event, profile: store.session.profileID, tab: tabID) }
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(event.query).font(.system(size: 15, design: .serif)).lineLimit(2)
                                    Text(event.date.formatted(date: .abbreviated, time: .shortened) + " · " + event.mode.rawValue).font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 22)
                            }.buttonStyle(.plain)
                        }.fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }.padding(22).frame(width: 380, height: 440)
        .alert("Delete \(selected.count) selected explorations?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                do {
                    try store.services?.ai.deleteHistory(selected, profile: store.session.profileID)
                    events.removeAll { selected.contains($0.id) }; selected = []; selecting = false
                } catch { historyError = "Couldn’t delete the selected history." }
            }
        } message: { Text("Their prompts, answers, references, visuals, and versions will be permanently deleted. This cannot be undone.") }
        .task { reload() }
        .onReceive(NotificationCenter.default.publisher(for: .origamiHistoryChanged)) { _ in reload() }
    }
    private func reload() {
        if !store.isPrivate { events = (try? store.services?.ai.repository.list(profile: store.session.profileID)) ?? []; selected.formIntersection(Set(events.map(\.id))) }
    }
}

/// Shared selector surface for provider search policy and searchable model catalogs.
struct AISettingsSelectionLabel: View {
    let title: String
    var body: some View {
        HStack(spacing: 8) {
            Text(title).lineLimit(1)
            Spacer(minLength: 4)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .medium)).accessibilityHidden(true)
        }.font(.body).foregroundStyle(.primary)
            .padding(.horizontal, 9).padding(.vertical, 5).frame(width: 220)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
    }
}

struct AskComposerOptions: View {
    @Binding var model: String
    @Binding var mode: AskMode
    @Bindable private var settings = AISettings.shared
    @State private var showing = false
    @State private var page = "Options"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button { page = "Options"; showing = true } label: {
            Image(systemName: "slider.horizontal.3").frame(width: 28, height: 28)
        }.buttonStyle(.plain).help("Model and answer options").accessibilityLabel("Model and answer options")
            .popover(isPresented: $showing) {
                VStack(spacing: 12) {
                    HStack {
                        if page != "Options" {
                            Button { page = "Options" } label: { Image(systemName: "chevron.left") }
                                .buttonStyle(.plain).accessibilityLabel("Back to options")
                        }
                        Text(page).font(.headline)
                        Spacer()
                    }.padding(.horizontal, 16).padding(.top, 16)
                    if page == "Model" {
                        ModelSearchList(didSelect: { page = "Options" }, selection: $model, allowsDefault: true)
                    } else if page == "Mode" {
                        VStack(spacing: 16) {
                            Text(mode.rawValue).font(.headline)
                            Slider(value: Binding(get: { Double(AskMode.allCases.firstIndex(of: mode) ?? 0) }, set: { mode = AskMode.allCases[Int($0.rounded())] }), in: 0...2, step: 1)
                                .accessibilityLabel("Answer mode").accessibilityValue(mode.rawValue)
                            HStack { ForEach(AskMode.allCases, id: \.self) { item in Button(item.rawValue) { mode = item }.buttonStyle(.plain).frame(maxWidth: .infinity) } }.font(.caption)
                        }.padding(16)
                    } else {
                        VStack(spacing: 16) {
                            option("Model", value: settings.displayName(model.isEmpty ? settings.routedModel(action: .web, mode: mode) : model), icon: "cpu")
                            option("Mode", value: mode.rawValue, icon: "slider.horizontal.3")
                            Toggle("Generated Visuals", isOn: $settings.generatedVisuals).toggleStyle(.switch).controlSize(.small)
                        }.padding(16)
                    }
                }.frame(width: 330).animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: page)
            }
    }
    private func option(_ title: String, value: String, icon: String) -> some View {
        Button { page = title } label: {
            HStack { Label(title, systemImage: icon); Spacer(); Text(value).foregroundStyle(.secondary).lineLimit(1); Image(systemName: "chevron.right").font(.caption) }
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
