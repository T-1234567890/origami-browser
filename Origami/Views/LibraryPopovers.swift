import SwiftUI

struct BookmarksPopover: View {
    let store: BrowserStore
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var folderID: UUID?
    @State private var items: [[String: Any]] = []
    @State private var folders: [BookmarkFolder] = []
    @State private var error: String?
    private var compact: Bool { _ = store.preferencesRevision; return store.preferences.compactBookmarks }
    private var childFolders: [BookmarkFolder] { search.isEmpty ? folders.filter { $0.parentID == folderID } : [] }
    private var empty: Bool { items.isEmpty && childFolders.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if let folderID {
                    Button { self.folderID = folders.first(where: { $0.id == folderID })?.parentID; refresh() } label: {
                        Image(systemName: "chevron.left").frame(width: 20, height: 22)
                    }.buttonStyle(.plain).help("Back to Parent Folder").accessibilityLabel("Back to Parent Folder")
                }
                Text(folderID.flatMap { id in folders.first(where: { $0.id == id })?.title } ?? "Bookmarks")
                    .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                Toggle(isOn: Binding(get: { compact }, set: { store.preferences.compactBookmarks = $0; store.preferencesRevision += 1 })) { Label("Compact View", systemImage: "list.bullet") }
                    .toggleStyle(.button).labelStyle(.iconOnly)
                    .help("Compact View").accessibilityLabel("Compact View")
            }
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search bookmarks", text: $search).textFieldStyle(.plain)
            }.font(.system(size: 12)).padding(8)
                .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
            if empty {
                LibraryEmptyState(symbol: "book", title: search.isEmpty ? "No bookmarks yet" : "No matching bookmarks",
                                  detail: search.isEmpty ? "Save a page with the star in the browser toolbar." : "Try another title or address.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(childFolders) { folder in
                            Button { folderID = folder.id; refresh() } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "folder").foregroundStyle(.secondary).frame(width: 20)
                                    Text(folder.title).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                                }
                            }.buttonStyle(LibraryRowStyle())
                        }
                        ForEach(items.indices, id: \.self) { index in
                            let item = items[index]
                            let address = item["url"] as? String ?? ""
                            Button {
                                if let url = URL(string: address) { store.newTab(url: url); dismiss() }
                            } label: {
                                HStack(spacing: 10) {
                                    SiteIcon(store: store, url: URL(string: address)).frame(width: 20)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item["title"] as? String ?? "Bookmark").lineLimit(1)
                                        if !compact { Text(URL(string: address)?.host ?? address)
                                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                                    }
                                    Spacer(minLength: 0)
                                }
                            }.buttonStyle(LibraryRowStyle()).help(address)
                        }
                    }
                }.frame(height: min(240, CGFloat(childFolders.count * 34 + items.count * (compact ? 32 : 48))))
            }
            if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
            LibraryFooter(title: "Open Bookmark Library") { store.openInternal(.bookmarks); dismiss() }
        }.padding(16).frame(width: 300)
            .task(id: search) {
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                refresh()
            }
            .onChange(of: store.bookmarkRevision) { refresh() }
    }
    private func refresh() {
        do {
            folders = try store.services?.bookmarks.folders(profileID: store.session.profileID) ?? []
            items = try store.services?.bookmarks.library(profileID: store.session.profileID, folderID: folderID, search: search) ?? []
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

struct DownloadsPopover: View {
    let store: BrowserStore
    @Environment(\.dismiss) private var dismiss
    @State private var items: [DownloadRecord] = []
    @State private var error: String?
    private var activeCount: Int { items.filter { $0.state == .running || $0.state == .choosingDestination }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Downloads").font(.system(size: 14, weight: .semibold))
                Spacer()
                if activeCount > 0 { Text("\(activeCount) active").font(.caption).foregroundStyle(.secondary) }
            }
            if items.isEmpty {
                LibraryEmptyState(symbol: "arrow.down.circle", title: "No downloads yet", detail: "Files you download will appear here.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(items) { item in DownloadPopoverRow(item: item) { action($0, item) } }
                    }
                }.frame(height: min(240, CGFloat(items.count * 70)))
            }
            if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
            LibraryFooter(title: "Show All Downloads") { store.openInternal(.downloads); dismiss() }
        }.padding(16).frame(width: 320)
            .task {
                while !Task.isCancelled {
                    refresh()
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
            }
    }
    private func refresh() {
        do { items = try store.services?.downloadRepository.list(profileID: store.session.profileID, limit: 20) ?? [] }
        catch { self.error = error.localizedDescription }
    }
    private func action(_ action: String, _ item: DownloadRecord) {
        Task { @MainActor in
            guard let tabID = store.selectedTab?.id else { return }
            do { _ = try await store.handleInternal("downloads.action", params: ["id": item.id.uuidString, "action": action], tabID: tabID); error = nil; refresh() }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct DownloadPopoverRow: View {
    let item: DownloadRecord
    let action: (String) -> Void
    @State private var hovered = false
    private var active: Bool { item.state == .running || item.state == .choosingDestination }
    private var status: String {
        let bytes = ByteCountFormatter.string(fromByteCount: item.received, countStyle: .file)
        switch item.state {
        case .running:
            if let expected = item.expected, expected > 0 { return "\(bytes) of \(ByteCountFormatter.string(fromByteCount: expected, countStyle: .file))" }
            return "\(bytes) downloaded"
        case .choosingDestination: return "Choose where to save"
        case .completed: return item.received > 0 ? "\(bytes) · Completed" : "Completed"
        case .cancelled: return "Cancelled"
        case .failed: return "Download failed"
        case .interrupted: return "Download interrupted"
        }
    }
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: item.state == .failed || item.state == .interrupted ? "exclamationmark.triangle" : "doc")
                .font(.system(size: 20, weight: .light)).foregroundStyle(.secondary).frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                Button { if item.state == .completed { action("open") } } label: {
                    Text(item.filename.isEmpty ? "Download" : item.filename)
                        .font(.system(size: 12, weight: .medium)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).disabled(item.state != .completed)
                Text(status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                if item.state == .running {
                    if let expected = item.expected, expected > 0 {
                        ProgressView(value: min(max(Double(item.received) / Double(expected), 0), 1)).progressViewStyle(.linear)
                    } else { ProgressView().controlSize(.mini) }
                }
            }
            if active {
                iconButton("xmark", title: "Cancel Download", action: "cancel")
            } else if item.state == .completed {
                iconButton("magnifyingglass", title: "Reveal in Finder", action: "reveal")
            } else if item.url.hasPrefix("https://") || item.url.hasPrefix("http://") {
                iconButton("arrow.clockwise", title: "Retry Download", action: "retry")
            }
        }.padding(.horizontal, 8).padding(.vertical, 9)
            .background(.primary.opacity(hovered ? 0.045 : 0), in: RoundedRectangle(cornerRadius: 6))
            .onHover { hovered = $0 }.help(item.error ?? item.filename)
    }
    private func iconButton(_ symbol: String, title: String, action name: String) -> some View {
        Button { action(name) } label: { Image(systemName: symbol).font(.system(size: 12)).frame(width: 24, height: 24) }
            .buttonStyle(.plain).foregroundStyle(.secondary).help(title).accessibilityLabel(title)
    }
}

private struct LibraryEmptyState: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 25, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 12, weight: .medium))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.vertical, 25)
    }
}

private struct LibraryFooter: View {
    let title: String
    let action: () -> Void
    var body: some View {
        VStack(spacing: 10) {
            Divider()
            Button(action: action) {
                HStack { Text(title); Spacer(); Image(systemName: "arrow.up.right").font(.system(size: 10)) }
                    .font(.system(size: 12)).foregroundStyle(.secondary).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
    }
}

private struct LibraryRowStyle: ButtonStyle {
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 7).contentShape(Rectangle())
            .background(.primary.opacity(configuration.isPressed ? 0.08 : hovered ? 0.045 : 0), in: RoundedRectangle(cornerRadius: 6))
            .onHover { hovered = $0 }
    }
}
