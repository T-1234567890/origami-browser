import SwiftUI

struct BrowserLibraryControls: View {
    let store: BrowserStore
    var toolbar = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var hasRelevantMedia: Bool {
        let windows = store.application.map { Array($0.stores.values) } ?? [store]
        return windows.contains { window in window.session.tabs.contains { window.loadedPage(for: $0.id)?.mediaState.isRelevant == true } }
    }
    @State private var showsMediaButton = false
    @State private var mediaVisible = false
    @State private var siteVisible = false
    @State private var bookmarksVisible = false
    @State private var downloadsVisible = false
    var body: some View {
        HStack(spacing: toolbar ? 4 : 12) {
            Button { siteVisible.toggle() } label: { icon("info.circle") }
                .help("Site Information").accessibilityLabel("Site Information")
                .popover(isPresented: $siteVisible) { SiteInformation(store: store) }
            Button { bookmarksVisible.toggle() } label: { icon("book") }
                .help("Bookmarks").accessibilityLabel("Bookmarks")
                .popover(isPresented: $bookmarksVisible) { BookmarksPopover(store: store) }
            Button { downloadsVisible.toggle() } label: {
                Group {
                    if store.services?.downloads.runningProfiles.contains(store.session.profileID) == true && !reduceMotion {
                        Image(systemName: "arrow.down.circle")
                            .symbolEffect(.bounce.down.byLayer, options: .repeating.speed(0.5), isActive: true)
                    } else {
                        Image(systemName: "arrow.down.circle")
                    }
                }.frame(width: 24, height: 24).contentShape(Rectangle())
            }
                .help("Downloads").accessibilityLabel("Downloads")
                .popover(isPresented: $downloadsVisible) { DownloadsPopover(store: store) }
            if showsMediaButton {
            Button { mediaVisible.toggle() } label: { icon("music.note.list") }
                .help("Media").accessibilityLabel("Media")
                .popover(isPresented: $mediaVisible) { MediaPopover(store: store) }
                .disabled(!hasRelevantMedia)
                .transition(.opacity)
            }
        }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
            .padding(.horizontal, toolbar ? 6 : 0)
            .padding(.vertical, toolbar ? 2 : 5)
            .fixedSize(horizontal: toolbar, vertical: true)
            .task(id: hasRelevantMedia) {
                let show = hasRelevantMedia
                do { try await Task.sleep(for: .milliseconds(show ? 120 : 450)) } catch { return }
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { showsMediaButton = show }
            }
            .onChange(of: hasRelevantMedia) { if !hasRelevantMedia { mediaVisible = false } }
            .preference(key: SidebarPopoverPreference.self, value: mediaVisible || siteVisible || bookmarksVisible || downloadsVisible)
    }
    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
    }
}

struct BookmarkBar: View {
    let store: BrowserStore
    @State private var bookmarks: [[String: Any]] = []
    @State private var folders: [BookmarkFolder] = []
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 16) {
                ForEach(folders.filter { $0.parentID == nil }) { folder in
                    Menu(folder.title) {
                        Button("Open as Tabs") { perform { try store.openFolder(folder.id) } }
                        Button("Open as Tab Group") { perform { try store.openFolder(folder.id, grouped: true) } }
                        Button("Show in Library") { store.openInternal(.bookmarks) }
                    }.menuStyle(.borderlessButton).fixedSize()
                }
                ForEach(bookmarks.indices, id: \.self) { index in
                    let item = bookmarks[index]
                    Button {
                        if let url = URL(string: item["url"] as? String ?? "") { store.newTab(url: url) }
                    } label: {
                        HStack(spacing: 6) {
                            SiteIcon(store: store, url: URL(string: item["url"] as? String ?? ""), size: 14)
                            Text(item["title"] as? String ?? "Bookmark").lineLimit(1)
                        }
                    }.frame(maxWidth: 160)
                }
                Button { store.bookmarkCurrentTab() } label: { Image(systemName: "star.badge.plus") }
                    .accessibilityLabel("Bookmark Current Tab")
            }.font(.system(size: 11)).buttonStyle(.plain).padding(.horizontal, 12).frame(height: 28)
        }.scrollIndicators(.hidden)
            .task(id: store.bookmarkRevision) { refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in refresh() }
    }
    private func refresh() {
        perform {
            bookmarks = try store.services?.bookmarks.library(profileID: store.session.profileID, folderID: nil) ?? []
            folders = try store.services?.bookmarks.folders(profileID: store.session.profileID) ?? []
        }
    }
    private func perform(_ action: () throws -> Void) { do { try action() } catch { store.persistenceError = error.localizedDescription } }
}

