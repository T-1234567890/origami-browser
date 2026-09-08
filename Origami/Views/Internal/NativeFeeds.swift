import SwiftUI
import UniformTypeIdentifiers

struct NativeFeeds: View {
    let model: InternalContentModel
    @State private var feeds: [FollowedFeed] = []
    @State private var articles: [FeedArticle] = []
    @State private var selected = ""
    @State private var unreadOnly = true
    @State private var query = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var busy = false
    @State private var adding = false
    @State private var address = ""
    @State private var folder = ""
    @State private var editing: FollowedFeed?
    private var service: FeedService? { model.store.services?.feeds }
    var body: some View {
        InternalContent(title: "Websites I Follow") {
            HStack(spacing: 14) {
                Menu {
                    Button("All Websites") { selected = "" }
                    ForEach(feeds) { feed in
                        Button((feed.folder.isEmpty ? "" : feed.folder + " / ") + feed.title) { selected = feed.id }
                    }
                } label: { Image(systemName: "line.3.horizontal.decrease") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Filter Websites")
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search articles or websites", text: $query).textFieldStyle(.plain)
                }.frame(maxWidth: .infinity)
                Button { unreadOnly.toggle() } label: {
                    Image(systemName: unreadOnly ? "envelope.badge" : "envelope.open")
                }.help(unreadOnly ? "Showing unread — show all" : "Showing all — show unread")
                Button { address = ""; folder = ""; adding = true } label: { Image(systemName: "plus") }.help("Follow Site")
                Menu {
                    Button("Refresh") { refreshFeeds() }
                    Button("Import OPML…", action: importOPML)
                    Button("Export OPML…", action: exportOPML)
                    if let feed = feeds.first(where: { $0.id == selected }) {
                        Button("Change Folder…") { editing = feed; folder = feed.folder }
                        Button("Unfollow", role: .destructive) { do { try service?.unfollow(feed); selected = ""; load() } catch { model.error = error.localizedDescription } }
                    }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Feed Actions")
                if busy { ProgressView().controlSize(.small) }
            }.buttonStyle(.plain).controlSize(.small).padding(.vertical, 8).disabled(busy)
            if let feed = feeds.first(where: { $0.id == selected }) {
                Text(feed.title).font(.caption).foregroundStyle(.secondary)
            }
            if filteredArticles.isEmpty {
                Text(query.isEmpty ? "No unread articles. Use Show All to see articles you’ve read." : "No matching articles.")
                    .foregroundStyle(.secondary).padding(.vertical, 24)
            }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(filteredArticles) { article in
                    HStack(alignment: .top, spacing: 10) {
                        Button { mark(article, read: !article.read) } label: { Circle().fill(article.read ? Color.secondary.opacity(0.25) : Personalization.shared.accent).frame(width: 7, height: 7).frame(width: 20, height: 24) }
                            .help(article.read ? "Mark Unread" : "Mark Read")
                        VStack(alignment: .leading, spacing: 5) {
                            Button(article.title) { open(article, reader: false) }.font(.body.weight(article.read ? .regular : .medium)).multilineTextAlignment(.leading)
                            Text((feeds.first { $0.id == article.feedID }?.title ?? "") + " · " + article.date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { open(article, reader: true) } label: { Image(systemName: "doc.text") }.help("Open in Reader when available")
                    }.buttonStyle(.plain).padding(.vertical, 12)
                        .transition(.opacity)
                    Divider()
                }
            }
        }.frame(maxWidth: 880).frame(maxWidth: .infinity, alignment: .top)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: filteredArticles.map(\.id))
        .task { load() }
        .popover(isPresented: $adding) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Follow Site").font(.headline)
                TextField("RSS or Atom feed URL", text: $address)
                TextField("Folder (optional)", text: $folder)
                Button("Follow") {
                    guard let url = URL(string: address) else { return }
                    adding = false; busy = true
                    Task {
                        do { try await service?.follow(url, profile: model.store.session.profileID, folder: folder); load() }
                        catch { model.error = error.localizedDescription }
                        busy = false
                    }
                }.disabled(address.isEmpty)
            }.padding(16).frame(width: 300)
        }
        .popover(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            VStack(spacing: 12) {
                TextField("Folder", text: $folder)
                Button("Save") {
                    if let editing { do { try service?.folder(editing, name: folder); load() } catch { model.error = error.localizedDescription } }
                    editing = nil
                }
            }.padding(16).frame(width: 240)
        }
    }
    private var filteredArticles: [FeedArticle] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return articles.filter { article in
            let feed = feeds.first { $0.id == article.feedID }
            return (selected.isEmpty || article.feedID == selected) && (!unreadOnly || !article.read) &&
                (text.isEmpty || article.title.localizedCaseInsensitiveContains(text) || (feed?.title ?? "").localizedCaseInsensitiveContains(text) || (feed?.folder ?? "").localizedCaseInsensitiveContains(text))
        }
    }
    private func load() {
        do { feeds = try service?.feeds(profile: model.store.session.profileID) ?? []; articles = try service?.articles(profile: model.store.session.profileID) ?? [] }
        catch { model.error = error.localizedDescription }
    }
    private func mark(_ article: FeedArticle, read: Bool) { do { try service?.mark(article, read: read); load() } catch { model.error = error.localizedDescription } }
    private func open(_ article: FeedArticle, reader: Bool) {
        guard let url = URL(string: article.url) else { return }
        mark(article, read: true)
        let id = model.store.newTab(url: url)
        model.store.page(for: id).readerWhenReady = reader
    }
    private func refreshFeeds() {
        busy = true
        Task {
            for feed in feeds {
                do { try await service?.refresh(feed) } catch { model.error = "Could not refresh \(feed.title). " + error.localizedDescription }
            }
            load(); busy = false
        }
    }
    private func importOPML() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.xml, UTType(filenameExtension: "opml") ?? .xml]; panel.allowsMultipleSelection = false
        guard let window = model.store.nativeWindow else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let entries = try OPMLParser().parse(Data(contentsOf: url))
                busy = true
                Task {
                    for (url, folder) in entries {
                        do { try await service?.follow(url, profile: model.store.session.profileID, folder: folder) }
                        catch { model.error = "Could not follow \(url.host ?? "feed"). " + error.localizedDescription }
                    }
                    load(); busy = false
                }
            } catch { model.error = error.localizedDescription }
        }
    }
    private func exportOPML() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Origami Feeds.opml"
        guard let window = model.store.nativeWindow else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            do { try service?.exportOPML(profile: model.store.session.profileID).write(to: url, options: .atomic) }
            catch { model.error = error.localizedDescription }
        }
    }
}
