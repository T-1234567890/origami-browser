import SwiftUI

struct MigrationView: View {
    let store: BrowserStore
    @State private var flow = MigrationFlow()
    var body: some View {
        InternalContent(title: "Import Browser Data") {
            MigrationImportContent(store: store, flow: flow)
        }
    }
}

/// Shared consumer flow; onboarding embeds it instead of opening another destination.
struct MigrationImportContent: View {
    let store: BrowserStore
    @Bindable var flow: MigrationFlow
    var onboarding = false
    var imported: ((BrowserSession) -> Void)?
    @State private var confirming = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if store.isPrivate {
                Text("Open a regular window to import browser data.")
            } else if flow.completed {
                Label("You’re ready to browse", systemImage: "checkmark.circle.fill").font(.headline)
                Text(flow.replace ? "Your selected data has been imported into this profile." : "Your data is saved in a separate profile. Your existing data is unchanged.").foregroundStyle(.secondary)
                if !onboarding { Button("Import Another Browser") { flow.reset() } }
            } else if let source = flow.source {
                HStack {
                    browserIcon(source)
                    Text(source.browser.rawValue).font(.headline)
                    Spacer()
                    Button("Change") { flow.reset() }.disabled(flow.busy)
                }
                if flow.busy {
                    HStack { Spacer(); ProgressView("Getting your data ready…"); Spacer() }.padding(.vertical, 20)
                } else if let profile = flow.profile {
                    if flow.profiles.count > 1 {
                        Picker("Profile", selection: $flow.selected) {
                            ForEach(flow.profiles) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        if profile.bookmarks != nil { Toggle("Bookmarks (\(profile.bookmarkCount))", isOn: $flow.selection.bookmarks) }
                        if let history = profile.history { Toggle("History (\(history.count))", isOn: $flow.selection.history) }
                        if let tabs = profile.tabs { Toggle("Open and pinned tabs (\(tabs.count))", isOn: $flow.selection.tabs) }
                        if profile.search != nil { Toggle("Use this browser’s search engine", isOn: $flow.selection.search) }
                    }.toggleStyle(.checkbox)
                    if !flow.replace { Text("Imported into a separate profile. Your existing browsing data stays as it is.").font(.callout).foregroundStyle(.secondary) }
                    if !profile.notes.isEmpty || !onboarding {
                        DisclosureGroup("More options & details") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(profile.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                                if !onboarding {
                                    Toggle("Replace data in the current profile instead", isOn: $flow.replace)
                                    if flow.replace { Text("This permanently overwrites selected data in this profile. Back up your data first.").foregroundStyle(.orange) }
                                }
                            }.padding(.top, 8)
                        }.font(.callout)
                    }
                    Button("Import") {
                        if flow.replace { confirming = true } else { performImport() }
                    }.buttonStyle(.borderedProminent).disabled(!flow.canImport)
                }
                if let error = flow.error {
                    Text(error).foregroundStyle(.secondary)
                    HStack {
                        Button("Try Again") { flow.choose(source) }
                        if flow.needsAccess { Button("Allow Access…") { flow.grantAccess() } }
                    }
                }
            } else {
                Text("Bring your bookmarks, history and tabs from another browser.").foregroundStyle(.secondary)
                if flow.sources.isEmpty {
                    Text("No supported browsers were found on this Mac. You can skip this and import later in Settings.").font(.callout)
                    Button("Check Again") { flow.sources = MigrationDiscovery.installed() }
                } else {
                    ForEach(flow.sources) { source in
                        Button { flow.choose(source) } label: {
                            HStack(spacing: 12) {
                                browserIcon(source)
                                Text(source.browser.rawValue)
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }.padding(10).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
                Text("Passwords and sign-ins stay with your other browser.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { if !store.isPrivate { flow.discover() } }
        .confirmationDialog("Replace this profile’s browsing data?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Replace Selected Data", role: .destructive) { performImport() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Selected bookmarks, history and tabs will be permanently replaced. This cannot be undone. Unavailable categories are kept.") }
    }
    private func browserIcon(_ source: MigrationSource) -> some View {
        Group {
            if let url = source.applicationURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit()
            } else { Image(systemName: "globe").resizable().scaledToFit().padding(4) }
        }.frame(width: 28, height: 28).accessibilityHidden(true)
    }
    private func performImport() {
        guard let profile = flow.profile else { return }
        do {
            let session = try store.importBrowserProfile(profile, selection: flow.selection, replace: flow.replace && !onboarding, openImported: !onboarding)
            flow.completed = true; flow.error = nil; imported?(session)
        } catch { flow.error = (error as? MigrationFailure)?.errorDescription ?? "Import couldn’t finish. Your other browser’s data is unchanged." }
    }
}
