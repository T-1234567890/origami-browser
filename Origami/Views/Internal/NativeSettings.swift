import SwiftUI

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case general = "General", appearance = "Appearance", tabs = "Tabs", search = "Search", downloads = "Downloads", privacy = "Privacy", ai = "AI"
    var id: Self { self }
    var icon: String {
        switch self {
        case .ai: "sparkles"
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
    @Environment(\.profileAppearance) private var appearance
    let model: InternalContentModel
    private var category: SettingsCategory { SettingsCategory(rawValue: model.store.settingsCategory) ?? .general }
    @State private var language = LanguageManager.shared
    @State private var pendingLanguage: AppLanguage?
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

    private var scopeLabel: String? {
        _ = model.store.application?.profileRevision
        guard let profile = try? model.store.services?.profiles.list().first(where: { $0.id == model.store.session.profileID }) else { return nil }
        return SettingsScope.label(category: category.rawValue, profile: profile)
    }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(SettingsCategory.allCases) { item in
                        Button { model.store.settingsCategory = item.rawValue } label: {
                            Label(L10n.string(item.rawValue), systemImage: item.icon)
                                .font(.system(size: 12, weight: category == item ? .semibold : .regular))
                                .padding(.horizontal, 12).padding(.vertical, 9)
                                .foregroundStyle(category == item ? appearance.accent : Color.secondary)
                                .background(category == item ? appearance.accent.opacity(0.14) : .clear,
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
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(L10n.string(category.rawValue)).font(.title2.weight(.semibold))
                    if let scopeLabel {
                        Label(scopeLabel, systemImage: scopeLabel == L10n.string("Synchronized with default profile") ? "arrow.triangle.2.circlepath" : "person.crop.circle").font(.caption).foregroundStyle(.secondary)
                            .help(category == .tabs ? L10n.string("Applies to tab layout. Other options on this page remain shared.") : scopeLabel == L10n.string("Synchronized with default profile") ? L10n.string("These settings are shared with the default profile.") : L10n.string("These settings apply to this profile."))
                    }
                }.padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 8)
                if category == .ai { AISettingsView(store: model.store) } else {
                Form {
                    switch category {
                    case .ai: EmptyView()
                    case .appearance: AppearanceSettings(layout: model.store.session.layout)
                    case .general:
                        Section("Language") {
                            Picker("App Language", selection: Binding(get: { language.selection }, set: {
                                if $0 != language.selection { pendingLanguage = $0 }
                            })) {
                                ForEach(AppLanguage.allCases) { Text(verbatim: $0.nativeName).tag($0) }
                            }
                        }
                        Section("Global Shortcuts") { GlobalShortcutSettings(store: model.store) }
                        Section {
                            Toggle("Restore previous session", isOn: setting($restore, key: "restore"))
                            actionRow("Welcome", action: "Show Again") { model.store.openInternal(.welcome) }
                            if !model.store.isPrivate {
                                actionRow("Import Browser Data", action: "Import…") { model.store.newTab(url: InternalPage.migration.url) }
                            }
                        }
                        if !model.store.isPrivate {
                            Section {
                                actionRow("Profiles", action: "Manage…") { model.open(InternalPage.profiles.url.absoluteString) }
                            }
                        }
                        Section { DefaultBrowserControl() }
                        Section("Peek") {
                            Picker("Link previews", selection: Binding(get: { model.store.peekMode }, set: { model.store.setPeekMode($0) })) {
                                ForEach(PeekMode.allCases) { Text($0.title).tag($0) }
                            }
                            Text(L10n.string("On Demand starts with a preview; swipe horizontally for details. Automatic starts with details. No AI is used."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let manager = model.store.services?.highlighter { WebHighlighterSettings(manager: manager) }
                        UpdatesSettings()
                        AboutSettings(store: model.store)
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
                            Text(L10n.string("Text you type may be sent to Brave to provide search suggestions."))
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
                                catch { model.store.persistenceError = L10n.string("History cleanup could not finish.") }
                            })) {
                                Text("30 days").tag(30); Text("90 days").tag(90); Text("180 days").tag(180); Text("1 year").tag(365); Text("Never").tag(0)
                            }.pickerStyle(.radioGroup)
                        } header: { Text("Automatically delete history") } footer: {
                            Text(L10n.string("Applies to browsing history, recently closed tabs, and inactive Ask histories across profiles. Cookies, website data, bookmarks and downloads are kept. Shortening this period deletes older history immediately."))
                        }
                        Section {
                            Toggle("Block pop-ups and autoplay by default", isOn: setting($strict, key: "privacy", encode: { $0 ? "strict" : "standard" }))
                        }
                        Section("Connection Security") {
                            Toggle("HTTPS-First", isOn: Binding(get: { model.store.preferences.httpsFirst }, set: {
                                model.store.preferences.httpsFirst = $0; model.store.preferencesRevision += 1
                            }))
                            Text(L10n.string("Try an encrypted connection first. If HTTPS is unavailable, block the page until you choose to continue over HTTP. Disabling this does not bypass certificate errors.")).font(.callout).foregroundStyle(.secondary)
                        }
                        if let blocking = model.store.services?.blocking { BlockingSettings(service: blocking) }
                        Section("Website Data & Permissions") {
                            actionRow("Website Data", action: "Manage…") { model.open(InternalPage.data.url.absoluteString) }
                            actionRow("Website Permissions", action: "Manage…") { model.open(InternalPage.permissions.url.absoluteString) }
                        }
                    }
                }
                .formStyle(.grouped).toggleStyle(.switch).controlSize(.regular)
                .font(.body)
                .scrollIndicators(.hidden)
                .disabled(!loaded)
                }
            }
            .frame(maxWidth: 680, maxHeight: .infinity, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
        }
        .alert("Change App Language?", isPresented: Binding(
            get: { pendingLanguage != nil },
            set: { if !$0 { pendingLanguage = nil } }
        ), presenting: pendingLanguage) { proposed in
            Button("Cancel", role: .cancel) { pendingLanguage = nil }
            Button("Change Language") {
                language.selection = proposed
                pendingLanguage = nil
            }
        } message: { proposed in
            Text(L10n.format("Change Origami’s language to %@? This applies immediately. Your open tabs and playback will continue.", proposed.nativeName))
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
            Text(L10n.string(title)).font(.body)
            Spacer(minLength: 16)
            Button(L10n.string(action), action: perform)
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
    @State private var sharing = ProfileSharing()
    @State private var showEditor = false
    @State private var deleting: BrowserProfile?
    @State private var busy = false
    var body: some View {
        InternalContent(title: "Profiles") {
            Text(L10n.string("Choose what each profile keeps separate or shares with the default profile. Tabs always stay separate.")).foregroundStyle(.secondary)
            ForEach(profiles) { profile in
                HStack(spacing: 12) {
                    Circle().fill(profile.color.tint).frame(width: 12, height: 12)
                    Text(profile.name)
                    if profile.id == model.store.session.profileID { Text("Current").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    if profile.id != model.store.session.profileID {
                        Button("Switch") { perform { _ = try model.store.application?.switchProfile(profile.id, in: model.store) } }
                    }
                    Button("Edit…") { editing = profile.id; name = profile.name; color = profile.color; sharing = profile.sharing; showEditor = true }
                    Button { deleting = profile } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Delete " + profile.name)
                        .disabled(profile.id == BrowserProfile.defaultID)
                        .help(profile.id == BrowserProfile.defaultID ? L10n.string("The default profile cannot be deleted.") : "Delete profile")
                }.padding(.vertical, 6)
                Divider()
            }
            Button("New Profile…") { editing = nil; name = ""; color = .mint; sharing = ProfileSharing(); showEditor = true }
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
                if editing != BrowserProfile.defaultID {
                    Text("Share with default profile").font(.subheadline.weight(.semibold))
                    ForEach(ProfileDataKind.allCases) { kind in
                        Toggle(kind.title, isOn: Binding(get: { sharing[kind] }, set: { sharing[kind] = $0 }))
                    }
                    Text(L10n.string("Sharing uses the default profile’s data without merging or deleting this profile’s own data. Turn sharing off to return to its own data. Deleting shared history or bookmarks affects all profiles using it."))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(L10n.string("Changing website sharing reloads this profile’s open pages. Save any unfinished forms first."))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(L10n.string("The default profile is the shared destination. Other profiles choose which categories to share with it."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(L10n.string("Open tabs, pins and tab groups stay separate. AI and search settings remain global."))
                    .font(.caption).foregroundStyle(.secondary)
                HStack { Spacer(); Button("Cancel") { showEditor = false }; Button("Save") {
                    perform {
                        guard let repository = model.store.services?.profiles else { throw RepositoryError.invalidInput }
                        if let editing {
                            try model.store.application?.updateProfile(editing, name: name, color: color, sharing: sharing)
                        } else {
                            _ = try repository.create(name: name, color: color, sharing: sharing)
                        }
                        model.store.application?.profileRevision += 1
                        refresh(); showEditor = false
                    }
                }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }.padding(20).frame(width: 420)
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
            Text(L10n.string("This closes this profile’s windows and deletes its own website data, history, bookmarks, permissions, and saved tabs. Shared Personal data and downloaded files remain."))
        }
    }
    private func refresh() { perform { profiles = try model.store.services?.profiles.list() ?? [] } }
    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { model.error = error.localizedDescription }
    }
}
