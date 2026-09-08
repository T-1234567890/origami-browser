import SwiftUI

struct BookmarkPageButton: View {
    let store: BrowserStore
    var iconSize: CGFloat = 11
    @State private var saved = false
    @State private var editing = false
    @State private var bookmark: Bookmark?
    @State private var title = ""
    @State private var urlText = ""
    @State private var folderID: UUID?
    @State private var folders: [BookmarkFolder] = []
    @State private var error: String?
    private var address: URL? { store.selectedTab?.url }
    private var canBookmark: Bool { address.map { ["http", "https"].contains($0.scheme) } ?? false }
    private var validURL: URL? {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme), url.host != nil else { return nil }
        return PersistedURL.clean(url)
    }

    var body: some View {
        Button(action: openEditor) {
            Image(systemName: saved ? "star.fill" : "star")
                .font(.system(size: iconSize)).frame(width: 20, height: 24)
        }
        .buttonStyle(.plain).foregroundStyle(saved ? Personalization.shared.accent : Color.secondary)
        .disabled(!canBookmark)
        .help(saved ? "Edit or Remove Bookmark" : "Bookmark This Page (⌘D)")
        .accessibilityLabel(saved ? "Edit or Remove Bookmark" : "Bookmark This Page")
        .popover(isPresented: $editing) { editor }
        .preference(key: SidebarPopoverPreference.self, value: editing)
        .onChange(of: address, initial: true) { editing = false; refresh() }
        .onChange(of: store.session.selectedTabID) { editing = false }
        .onChange(of: store.bookmarkRevision) { refresh() }
    }
    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bookmark").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow { Text("Name"); TextField("Name", text: $title) }
                GridRow { Text("URL"); TextField("URL", text: $urlText) }
                GridRow {
                    Text("Folder")
                    Picker("Folder", selection: $folderID) {
                        Text("Bookmarks").tag(nil as UUID?)
                        ForEach(folders) { folder in Text(folder.title).tag(Optional(folder.id)) }
                    }.labelsHidden().frame(maxWidth: .infinity, alignment: .trailing)
                }
            }.textFieldStyle(.roundedBorder)
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Remove Bookmark", role: .destructive, action: remove)
                Spacer()
                Button("Done", action: save).keyboardShortcut(.defaultAction)
                    .disabled(validURL == nil || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.font(.system(size: 12)).padding(16).frame(width: 320).fixedSize(horizontal: false, vertical: true)
    }
    private func openEditor() {
        guard let address, let repository = store.services?.bookmarks else { return }
        do {
            if try repository.bookmark(url: address, profileID: store.session.profileID) == nil {
                _ = try repository.addUnique(url: address, title: store.selectedTab?.title ?? address.absoluteString, profileID: store.session.profileID)
            }
            guard let record = try repository.bookmark(url: address, profileID: store.session.profileID) else { return }
            bookmark = record; title = record.title; urlText = record.url; folderID = record.folderID
            folders = try repository.folders(profileID: store.session.profileID)
            error = nil; saved = true; store.bookmarkRevision += 1; editing = true
        } catch { store.persistenceError = error.localizedDescription }
    }
    private func save() {
        guard let bookmark, let validURL else { return }
        do {
            try store.services?.bookmarks.editDetails(bookmark.id, url: validURL, title: title, folderID: folderID, profileID: store.session.profileID)
            store.bookmarkRevision += 1; editing = false; refresh()
        } catch { self.error = error.localizedDescription }
    }
    private func remove() {
        guard let bookmark, let url = URL(string: bookmark.url) else { return }
        do {
            try store.services?.bookmarks.removePage(url: url, profileID: store.session.profileID)
            store.bookmarkRevision += 1; editing = false; refresh()
        } catch { self.error = error.localizedDescription }
    }
    private func refresh() {
        guard let address, canBookmark else { saved = false; return }
        do { saved = try store.services?.bookmarks.contains(url: address, profileID: store.session.profileID) ?? false }
        catch { saved = false }
    }
}
