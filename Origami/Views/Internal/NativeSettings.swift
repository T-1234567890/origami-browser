import SwiftUI

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case general = "General", appearance = "Appearance", tabs = "Tabs", search = "Search", downloads = "Downloads", privacy = "Privacy", ai = "AI"
    var id: Self { self }
    var icon: String {
        switch self {
        case .ai: "text.magnifyingglass"
        case .appearance: "paintpalette"
        case .general: "gearshape"
        case .tabs: "rectangle.on.rectangle"
        case .search: "magnifyingglass"
        case .downloads: "arrow.down.circle"
        case .privacy: "hand.raised"
        }
    }
}

struct NativeSettings: View {
    let model: InternalContentModel
    private var category: SettingsCategory { SettingsCategory(rawValue: model.store.settingsCategory) ?? .general }
    @State private var layout = TabLayout.horizontal
    @State private var engine = SearchEngine.google
    @State private var restore = true
    @State private var bookmarkBar = false
    @State private var sleeping = false
    @State private var askDownload = true
    @State private var strict = false
    @State private var braveSuggestions = true
    @State private var privateBraveSuggestions = false
    @State private var loaded = false
    @State private var retentionDays = 90

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(SettingsCategory.allCases) { item in
                        Button { model.store.settingsCategory = item.rawValue } label: {
                            Label(item.rawValue, systemImage: item.icon)
                                .font(.system(size: 12, weight: category == item ? .semibold : .regular))
                                .padding(.horizontal, 12).padding(.vertical, 9)
                                .foregroundStyle(category == item ? Personalization.shared.accent : Color.secondary)
                                .background(category == item ? Personalization.shared.accent.opacity(0.14) : .clear,
                                            in: RoundedRectangle(cornerRadius: 7))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(category == item ? .isSelected : [])
                    }
                }.padding(.horizontal, 20).padding(.vertical, 12)
            }
            .scrollIndicators(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .background(.regularMaterial)
            .accessibilityLabel("Settings categories")
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(category.rawValue).font(.title2.weight(.semibold))
                    .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 8)
                if category == .ai { AISettingsView(store: model.store) } else {
                Form {
                    switch category {
                    case .ai: EmptyView()
                    case .appearance: AppearanceSettings(layout: model.store.session.layout)
                    case .general:
                        Section("Global Shortcuts") { GlobalShortcutSettings(store: model.store) }
                        Section {
                            Toggle("Restore previous session", isOn: setting($restore, key: "restore"))
                            actionRow("Welcome", action: "Show Again") { model.store.openInternal(.welcome) }
                        }
                        if !model.store.isPrivate {
                            Section {
                                actionRow("Profiles", action: "Manage…") { model.open(InternalPage.profiles.url.absoluteString) }
                            }
                        }
                        UpdatesSettings()
                        AboutSettings()
                    case .tabs:
                        Section {
                            Picker("Tab layout", selection: setting($layout, key: "layout", encode: { $0.rawValue })) {
                                Text("Horizontal").tag(TabLayout.horizontal)
                                Text("Vertical").tag(TabLayout.vertical)
                            }
                            if BrowserFeatureFlags.compactSidebar && layout == .vertical {
                                Picker("Sidebar behavior", selection: Binding(get: { model.store.sidebarBehavior }, set: { model.store.setSidebarBehavior($0) })) {
                                    ForEach(SidebarBehavior.allCases) { Text($0.title).tag($0) }
                                }
                            }
                            Toggle("Show bookmark bar", isOn: setting($bookmarkBar, key: "bookmarkBar"))
                        }
                        Section {
                            Toggle("Automatically sleep inactive tabs", isOn: setting($sleeping, key: "sleeping"))
                        }
                    case .search:
                        Section {
                            Picker("Search engine", selection: setting($engine, key: "search", encode: { $0.rawValue })) {
                                ForEach(SearchEngine.allCases) { Text($0.displayName).tag($0) }
                            }
                        }
                        Section {
                            Toggle("Show suggestions from Brave", isOn: setting($braveSuggestions, key: "braveSuggestions"))
                            Toggle("Allow suggestions in Private Browsing", isOn: setting($privateBraveSuggestions, key: "privateBraveSuggestions"))
                        } footer: {
                            Text("Text you type may be sent to Brave to provide search suggestions.")
                        }
                    case .downloads:
                        Section {
                            Toggle("Ask where to save files", isOn: setting($askDownload, key: "askDownload"))
                            actionRow("Download folder", action: "Choose…") { Task { await model.call("downloads.directory") } }
                        }
                    case .privacy:
                        Section {
                            Picker("Keep history for", selection: Binding(get: { retentionDays }, set: { days in
                                retentionDays = days; model.store.preferences.historyRetentionDays = days
                                do { try (model.store.application?.services ?? model.store.services)?.runHistoryCleanup() }
                                catch { model.store.persistenceError = "History cleanup could not finish." }
                            })) {
                                Text("30 days").tag(30); Text("90 days").tag(90); Text("180 days").tag(180); Text("1 year").tag(365); Text("Never").tag(0)
                            }.pickerStyle(.radioGroup)
                        } header: { Text("Automatically delete history") } footer: {
                            Text("Applies to browsing history, recently closed tabs, and inactive Ask histories across profiles. Cookies, website data, bookmarks and downloads are kept. Shortening this period deletes older history immediately.")
                        }
                        Section {
                            Toggle("Block pop-ups and autoplay by default", isOn: setting($strict, key: "privacy", encode: { $0 ? "strict" : "standard" }))
                        }
                        Section {
                            actionRow("Website Data", action: "Manage…") { model.open(InternalPage.data.url.absoluteString) }
                            actionRow("Website Permissions", action: "Manage…") { model.open(InternalPage.permissions.url.absoluteString) }
                        }
                    }
                }
                .formStyle(.grouped).toggleStyle(.switch).controlSize(.small)
                .disabled(!loaded)
                }
            }
            .frame(maxWidth: 680, maxHeight: .infinity, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .scrollContentBackground(.hidden)
        }
        .task {
            guard let values = await model.call("settings.read") as? [String: Any] else { return }
            layout = model.store.session.layout; engine = model.store.session.searchEngine
            restore = values["restore"] as? Bool ?? true; bookmarkBar = values["bookmarkBar"] as? Bool ?? false
            sleeping = values["sleeping"] as? Bool ?? false; askDownload = values["askDownload"] as? Bool ?? true
            braveSuggestions = values["braveSuggestions"] as? Bool ?? true
            privateBraveSuggestions = values["privateBraveSuggestions"] as? Bool ?? false
            strict = values.text("privacy") == "strict"
            retentionDays = model.store.preferences.historyRetentionDays
            loaded = true
        }
    }

    private func actionRow(_ title: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 16)
            Button(action, action: perform)
        }
    }

    // Persist only the edited preference, so unrelated changes in other windows are not overwritten.
    private func setting<Value>(_ binding: Binding<Value>, key: String, encode: @escaping (Value) -> Any = { $0 }) -> Binding<Value> {
        Binding(get: { binding.wrappedValue }, set: { value in
            binding.wrappedValue = value
            Task { @MainActor in
                var params: [String: Any] = ["layout": model.store.session.layout.rawValue,
                    "search": model.store.session.searchEngine.rawValue, "restore": model.store.session.restoreSession]
                params[key] = encode(value)
                await model.call("settings.write", params)
            }
        })
    }
}

struct NativeProfiles: View {
    let model: InternalContentModel
    @State private var profiles: [BrowserProfile] = []
    @State private var editing: UUID?
    @State private var name = ""
    @State private var color = ProfileColor.mint
    @State private var showEditor = false
    @State private var deleting: BrowserProfile?
    @State private var busy = false
    var body: some View {
        InternalContent(title: "Profiles") {
            Text("Separate website data, logins, history, and tabs.").foregroundStyle(.secondary)
            ForEach(profiles) { profile in
                HStack(spacing: 12) {
                    Circle().fill(profile.color.tint).frame(width: 12, height: 12)
                    Text(profile.name)
                    if profile.id == model.store.session.profileID { Text("Current").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    if profile.id != model.store.session.profileID {
                        Button("Switch") { perform { _ = try model.store.application?.switchProfile(profile.id, in: model.store) } }
                    }
                    Button("Edit…") { editing = profile.id; name = profile.name; color = profile.color; showEditor = true }
                    if profile.id != BrowserProfile.defaultID {
                        Button { deleting = profile } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Delete " + profile.name)
                    }
                }.padding(.vertical, 6)
                Divider()
            }
            Button("New Profile…") { editing = nil; name = ""; color = .mint; showEditor = true }
        }
        .disabled(busy || model.store.isPrivate)
        .task { refresh() }
        .sheet(isPresented: $showEditor) {
            VStack(alignment: .leading, spacing: 16) {
                Text(editing == nil ? "New Profile" : "Edit Profile").font(.headline)
                TextField("Name", text: $name)
                HStack(spacing: 12) {
                    ForEach(ProfileColor.allCases, id: \.self) { option in
                        Button { color = option } label: {
                            Circle().fill(option.tint).frame(width: 24, height: 24)
                                .overlay { if color == option { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white) } }
                        }.buttonStyle(.plain).accessibilityLabel(option.rawValue.capitalized)
                            .accessibilityAddTraits(color == option ? .isSelected : [])
                    }
                }
                HStack { Spacer(); Button("Cancel") { showEditor = false }; Button("Save") {
                    perform {
                        guard let repository = model.store.services?.profiles else { throw RepositoryError.invalidInput }
                        if let editing { try repository.update(editing, name: name, color: color) }
                        else { _ = try repository.create(name: name, color: color) }
                        model.store.application?.profileRevision += 1
                        refresh(); showEditor = false
                    }
                }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }.padding(20).frame(width: 300)
        }
        .alert("Delete Profile?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) {
                guard let id = deleting?.id else { return }
                deleting = nil; busy = true
                Task {
                    do { try await model.store.application?.deleteProfile(id); refresh() }
                    catch { model.error = error.localizedDescription }
                    busy = false
                }
            }
        } message: {
            Text("This closes this profile’s windows and deletes its website data, history, bookmarks, permissions, and saved tabs. Downloaded files remain.")
        }
    }
    private func refresh() { perform { profiles = try model.store.services?.profiles.list() ?? [] } }
    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { model.error = error.localizedDescription }
    }
}
