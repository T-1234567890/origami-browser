import Observation
import WebKit

@MainActor @Observable
final class BrowserStore {
    var session: BrowserSession
    var recentlyClosed: [(tab: BrowserTab, index: Int)] = []
    @ObservationIgnored weak var application: BrowserApplicationContext?
    @ObservationIgnored let preferences: BrowserPreferences
    @ObservationIgnored let services: BrowserServices?
    var isPrivate: Bool { services?.isPrivate == true }
    var bookmarkRevision = 0
    var preferencesRevision = 0
    var settingsCategory = "General"
    var splitDropPreview: PageSplitDropTarget?
    @ObservationIgnored var pageDropFrames: [UUID: CGRect] = [:]
    var showingFind = false
    var showingAISetup = false
    @ObservationIgnored var lifecycleTask: Task<Void, Never>?
    var focusRequest = UUID()
    var peekAnchor = CGPoint(x: 0.5, y: 0.25)
    var peekLinkBounds: CGRect?
    var peekViewport = CGSize(width: 1200, height: 900)
    var peekSourceID: UUID?
    var peekDismissGeneration = UUID()
    var peekInteracting = false
    var peekPage: TabPage?
    var persistenceError: String?
    var confirmationMessage: String?
    @ObservationIgnored var confirmationContinuation: CheckedContinuation<Bool, Never>?
    var nativeWindow: NSWindow? { application?.states[session.windowID]?.window }
    func resolveConfirmation(_ approved: Bool) {
        confirmationMessage = nil
        let continuation = confirmationContinuation; confirmationContinuation = nil
        continuation?.resume(returning: approved)
    }
    @ObservationIgnored let persistence: SessionStore?
    var pages: [UUID: TabPage] = [:]
    var selectedTab: BrowserTab? { session.tabs.first { $0.id == session.selectedTabID } }
    var isShowingWelcome: Bool { selectedTab?.url.flatMap(InternalRoute.page(for:)) == .welcome }
    var visiblePage: TabPage? {
        guard let tab = selectedTab, tab.isSleeping != true else { return nil }
        return pages[tab.id]
    }
    func prepareSelectedPage() {
        guard let tab = selectedTab, tab.isSleeping != true, pages[tab.id] == nil else { return }
        _ = page(for: tab.id)
    }
    var selectedPage: TabPage? { guard selectedTab?.isSleeping != true else { return nil }; return session.selectedTabID.map { page(for: $0) } }

    init(session: BrowserSession? = nil, persistence: SessionStore? = nil, services sharedServices: BrowserServices? = nil, preferences: BrowserPreferences? = nil) {
        self.persistence = sharedServices?.isPrivate == true ? nil : persistence
        self.preferences = preferences ?? persistence?.preferences ?? BrowserPreferences()
        var initial = session ?? BrowserSession()
        if session == nil, let persistence {
            do { initial = try persistence.load() }
            catch { persistenceError = "The previous session could not be read. \(error.localizedDescription)" }
        }
        initial.normalize()
        self.session = initial
        do {
            let database = try persistence?.database ?? DatabaseManager()
            let initializedServices = try sharedServices ?? BrowserServices(database: database)
            if sharedServices?.isPrivate != true, let persistence, initial.restoreSession {
                recentlyClosed = try RecentlyClosedRepository(persistence.database).list(profileID: initial.profileID, windowID: initial.windowID)
            }
            services = initializedServices
        } catch {
            services = nil
            persistenceError = "Browser storage is unavailable. Existing data has not been replaced. \(error.localizedDescription)"
        }
        if sharedServices == nil { services?.downloads.onError = { [weak self] in self?.persistenceError = $0 } }
    }
    var profilePinCount: Int {
        guard !isPrivate, let application else { return session.tabs.filter(\.isPinned).count }
        return application.stores.values.filter { !$0.isPrivate && $0.session.profileID == session.profileID }
            .reduce(0) { $0 + $1.session.tabs.filter(\.isPinned).count }
    }
    func save() {
        if !isPrivate, let application {
            let otherPins = application.stores.values.filter { $0 !== self && !$0.isPrivate && $0.session.profileID == session.profileID }
                .reduce(0) { $0 + $1.session.tabs.filter(\.isPinned).count }
            var available = max(0, BrowserSession.maximumPinnedTabs - otherPins)
            for index in session.tabs.indices where session.tabs[index].isPinned {
                if available > 0 { available -= 1 } else { session.tabs[index].isPinned = false }
            }
        }
        do { try persistence?.save(session, recentlyClosed: recentlyClosed, savePreferences: false) }
        catch { persistenceError = "Your session could not be saved. \(error.localizedDescription)" }
    }
    func loadedPage(for id: UUID) -> TabPage? { pages[id] }
    func page(for id: UUID, configuration: WKWebViewConfiguration? = nil) -> TabPage {
        if let page = pages[id] { return page }
        let page = TabPage(configuration: configuration, services: services, profileID: session.profileID, tabID: id)
        pages[id] = page
        bind(page, to: id)
        if configuration == nil { page.load(session.tabs.first(where: { $0.id == id })?.url ?? InternalRoute.newTabURL) }
        return page
    }
    func bind(_ page: TabPage, to id: UUID) {
        page.onServiceError = { [weak self] in self?.persistenceError = $0 }
        page.onChange = { [weak self, weak page] in
            guard let self, let page, let index = self.session.tabs.firstIndex(where: { $0.id == id }) else { return }
            let url = page.currentURL ?? self.session.tabs[index].url
            let title = page.pageTitle ?? url?.host ?? "New Tab"
            if self.session.tabs[index].url != url || self.session.tabs[index].title != title {
                self.session.tabs[index].url = url
                self.session.tabs[index].title = title
                self.save()
            }
        }
        page.openPeek = { [weak self] url in self?.openPeek(url) }
        page.linkPeekObserver.changed = { [weak self, weak page] url, point in
            guard let self, let page, page.nativePage == nil, self.session.selectedTabID == page.tabID else { return }
            guard let url else { if self.peekSourceID == page.tabID { self.deferPeekDismissal() }; return }
            self.peekDismissGeneration = UUID()
            if self.peekPage?.currentURL != url { self.openPeek(url) }
            self.peekLinkBounds = page.linkPeekObserver.linkBounds
            let size = page.webView.bounds.size
            if size.width > 0 && size.height > 0 { self.peekViewport = size }
            self.peekAnchor = point; self.peekSourceID = page.tabID
        }
        page.openTab = { [weak self] request in
            guard let self else { return }
            self.newTab(url: request.url)
        }
        page.createPopup = { [weak self] configuration in
            guard let self else {
                let webView = WKWebView(frame: .zero, configuration: configuration)
                webView.isInspectable = true
                return webView
            }
            let id = self.newTab()
            return self.page(for: id, configuration: configuration).webView
        }
    }
    @discardableResult func newTab(url: URL? = nil, groupID: UUID? = nil) -> UUID {
        let tab = BrowserTab(url: url, groupID: groupID)
        session.tabs.append(tab)
        select(tab.id)
        if url == nil { focusRequest = UUID() }
        return tab.id
    }
    func select(_ id: UUID) {
        if session.tabs.first(where: { $0.id == id })?.isSleeping == true { wake(id) }
        guard session.tabs.contains(where: { $0.id == id }) else { return }
        if let previous = session.selectedTabID { pages[previous]?.activity.lastActive = Date() }
        if session.selectedTabID != id { resolveConfirmation(false) }
        session.selectedTabID = id
        pages[id]?.activity.lastActive = Date()
        if let groupID = selectedTab?.groupID, let index = session.groups.firstIndex(where: { $0.id == groupID }) {
            session.groups[index].isCollapsed = false
        }
        if let split = session.activeSplit,
           let groupID = session.tabs.first(where: { $0.id == split.left })?.groupID,
           let index = session.groups.firstIndex(where: { $0.id == groupID }) {
            session.groups[index].isCollapsed = false
        }
        save()
    }
    func close(_ id: UUID) {
        services?.ai.release(id)
        if session.selectedTabID == id { resolveConfirmation(false) }
        guard let index = session.tabs.firstIndex(where: { $0.id == id }) else { return }
        let remainingSplitTab = session.activeSplit.map { $0.left == id ? $0.right : $0.left }
        let removed = session.tabs.remove(at: index)
        if !isPrivate && removed.canReopen { recentlyClosed.append((removed, index)) }
        recentlyClosed = Array(recentlyClosed.suffix(20))
        pages.removeValue(forKey: id)?.dispose()
        if session.selectedTabID == id {
            session.selectedTabID = remainingSplitTab ?? (session.tabs.isEmpty ? nil : session.tabs[min(index, session.tabs.count - 1)].id)
        }
        session.normalize()
        save()
    }
    func reopenClosedTab() {
        guard var closed = recentlyClosed.popLast() else { return }
        if !session.groups.contains(where: { $0.id == closed.tab.groupID }) { closed.tab.groupID = nil }
        session.tabs.insert(closed.tab, at: min(closed.index, session.tabs.count))
        session.normalize()
        select(closed.tab.id)
    }
    func duplicate(_ id: UUID) {
        guard let tab = session.tabs.first(where: { $0.id == id }) else { return }
        newTab(url: tab.url, groupID: tab.groupID)
    }
    func togglePin(_ id: UUID) {
        guard let index = session.tabs.firstIndex(where: { $0.id == id }) else { return }
        guard session.tabs[index].isPinned || profilePinCount < BrowserSession.maximumPinnedTabs else {
            persistenceError = "You can pin up to six tabs. Unpin one to make room."
            return
        }
        session.tabs[index].isPinned.toggle()
        session.tabs[index].groupID = nil
        session.normalize(); save()
    }
    func move(_ id: UUID, before targetID: UUID) {
        guard id != targetID, let source = session.tabs.firstIndex(where: { $0.id == id }),
              let target = session.tabs.first(where: { $0.id == targetID }),
              target.isPinned == session.tabs[source].isPinned else { return }
        var tab = session.tabs.remove(at: source)
        tab.groupID = target.groupID
        let destination = session.tabs.firstIndex { $0.id == targetID }!
        session.tabs.insert(tab, at: destination)
        save()
    }
    func swapTabs(_ id: UUID, with targetID: UUID) {
        guard id != targetID,
              let source = session.tabs.firstIndex(where: { $0.id == id }),
              let target = session.tabs.firstIndex(where: { $0.id == targetID }),
              session.tabs[source].isPinned == session.tabs[target].isPinned else { return }
        // Groups are positions in the visible strip, so swap membership with position.
        let sourceGroup = session.tabs[source].groupID
        session.tabs[source].groupID = session.tabs[target].groupID
        session.tabs[target].groupID = sourceGroup
        session.tabs.swapAt(source, target)
        save()
    }

    func dropTab(_ id: UUID, target: TabDropTarget) {
        switch target {
        case .group(let group): finishTabDrag(id, groupID: group)
        case .end: finishTabDrag(id, groupID: nil, atEnd: true)
        case .tab(let targetID, let after):
            guard id != targetID, let source = session.tabs.firstIndex(where: { $0.id == id }),
                  let target = session.tabs.first(where: { $0.id == targetID }),
                  session.tabs[source].isPinned == target.isPinned else { return }
            var tab = session.tabs.remove(at: source)
            if tab.groupID != target.groupID { tab.groupID = nil }
            let destination = session.tabs.firstIndex(where: { $0.id == targetID })!
            session.tabs.insert(tab, at: destination + (after ? 1 : 0)); save()
        }
    }
    /// Move a group as a unit without adopting tabs from the destination.
    func dropGroup(_ id: UUID, target: TabDropTarget) {
        guard let groupIndex = session.groups.firstIndex(where: { $0.id == id }) else { return }
        let members = session.tabs.filter { $0.groupID == id }
        var remaining = session.tabs.filter { $0.groupID != id }
        let destination: Int
        switch target {
        case .group(let other):
            guard other != id, let group = session.groups.first(where: { $0.id == other }) else { return }
            destination = remaining.firstIndex { $0.groupID == other } ?? min(group.anchorIndex ?? remaining.count, remaining.count)
        case .tab(let tabID, let after):
            guard let index = remaining.firstIndex(where: { $0.id == tabID }), !remaining[index].isPinned else { return }
            destination = index + (after ? 1 : 0)
        case .end: destination = remaining.count
        }
        let insertion = max(remaining.prefix(while: \.isPinned).count, destination)
        remaining.insert(contentsOf: members, at: insertion)
        session.tabs = remaining
        session.groups[groupIndex].anchorIndex = insertion
        // Keep empty groups at the same anchor in the intended order, too.
        if case .group(let other) = target {
            let group = session.groups.remove(at: groupIndex)
            session.groups.insert(group, at: session.groups.firstIndex { $0.id == other }!)
        }
        save()
    }

    func dragTab(_ id: UUID, onto targetID: UUID) {
        guard id != targetID, let from = session.tabs.firstIndex(where: { $0.id == id }),
              let to = session.tabs.firstIndex(where: { $0.id == targetID }),
              session.tabs[from].isPinned == session.tabs[to].isPinned else { return }
        // Reorder without inferring membership from the tab under the pointer.
        session.tabs.swapAt(from, to)
        save()
    }
    func finishTabDrag(_ id: UUID, groupID: UUID?, atEnd: Bool = false) {
        guard let index = session.tabs.firstIndex(where: { $0.id == id }), !session.tabs[index].isPinned else { return }
        if let groupID {
            guard session.groups.contains(where: { $0.id == groupID }) else { return }
            var tab = session.tabs.remove(at: index); tab.groupID = groupID
            let anchor = session.groups.first(where: { $0.id == groupID })?.anchorIndex ?? session.tabs.count
            let destination = session.tabs.lastIndex(where: { $0.groupID == groupID }).map { $0 + 1 } ?? min(max(anchor, 0), session.tabs.count)
            session.tabs.insert(tab, at: destination)
        } else {
            session.tabs[index].groupID = nil
            if atEnd { let tab = session.tabs.remove(at: index); session.tabs.append(tab) }
        }
        session.normalize(); save()
    }
    func setGroupColor(_ id: UUID, color: TabGroupColor) {
        guard let index = session.groups.firstIndex(where: { $0.id == id }) else { return }
        session.groups[index].color = color.permitted; save()
    }
    func moveBy(_ id: UUID, offset: Int) {
        guard let tab = session.tabs.first(where: { $0.id == id }) else { return }
        let peers = session.tabs.filter { $0.isPinned == tab.isPinned && $0.groupID == tab.groupID }
        guard let index = peers.firstIndex(where: { $0.id == id }), peers.indices.contains(index + offset),
              let a = session.tabs.firstIndex(where: { $0.id == id }),
              let b = session.tabs.firstIndex(where: { $0.id == peers[index + offset].id }) else { return }
        session.tabs.swapAt(a, b); save()
    }
    @discardableResult func createGroup(name: String, tabID: UUID? = nil) -> UUID {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = TabGroup(name: name.isEmpty ? "Untitled Group" : name, color: .purple, anchorIndex: session.tabs.count)
        session.groups.append(group)
        if let tabID { setGroup(tabID, groupID: group.id) }
        save(); return group.id
    }
    func setGroup(_ id: UUID, groupID: UUID?) {
        guard let index = session.tabs.firstIndex(where: { $0.id == id }),
              groupID == nil || session.groups.contains(where: { $0.id == groupID }) else { return }
        session.tabs[index].groupID = groupID
        if groupID != nil { session.tabs[index].isPinned = false }
        session.normalize(); save()
    }
    func renameGroup(_ id: UUID, name: String) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let index = session.groups.firstIndex(where: { $0.id == id }) else { return }
        session.groups[index].name = name; save()
    }
    func toggleGroup(_ id: UUID) {
        guard let index = session.groups.firstIndex(where: { $0.id == id }) else { return }
        session.groups[index].isCollapsed.toggle(); save()
    }
    func removeGroup(_ id: UUID) {
        session.groups.removeAll { $0.id == id }
        for index in session.tabs.indices where session.tabs[index].groupID == id { session.tabs[index].groupID = nil }
        save()
    }
    var sidebarBehavior: SidebarBehavior { _ = preferencesRevision; return BrowserFeatureFlags.sidebarBehavior(preferences.sidebarBehavior) }
    func setSidebarBehavior(_ behavior: SidebarBehavior) {
        guard behavior == .visible || BrowserFeatureFlags.compactSidebar else { return }
        for store in application.map({ Array($0.stores.values) }) ?? [self] {
            store.preferences.sidebarBehavior = behavior
            store.preferencesRevision += 1
        }
    }
    func toggleSidebar() {
        guard session.layout == .vertical else { return }
        setSidebarBehavior(sidebarBehavior == .visible ? .compact : .visible)
    }
    func expandSidebarFromEmptySpace() {
        guard session.layout == .vertical, sidebarBehavior == .compact else { return }
        setSidebarBehavior(.visible)
    }
    func focusOmnibox() {
        focusRequest = UUID()
    }
    func setLayout(_ layout: TabLayout) { session.layout = layout; preferences.layout = layout; save() }
    func setSearchEngine(_ engine: SearchEngine) {
        preferences.searchEngine = engine
        for store in application.map({ Array($0.stores.values) }) ?? [self] { store.session.searchEngine = engine; store.save() }
    }
    func setRestoreSession(_ restore: Bool) { session.restoreSession = restore; preferences.restoreSession = restore; save() }
    func navigate(_ input: String, searchOnly: Bool = false) {
        guard let url = searchOnly ? session.searchEngine.searchURL(for: input) : OmniboxRouter.destination(for: input, engine: session.searchEngine) else { return }
        guard let id = session.selectedTabID else {
            let id = newTab(url: url)
            _ = page(for: id)
            return
        }
        guard let index = session.tabs.firstIndex(where: { $0.id == id }) else { return }
        let page = page(for: id)
        session.tabs[index].url = url
        page.load(url); save()
    }
    func updateWindowFrame(_ frame: String) {
        guard session.windowFrame != frame else { return }
        session.windowFrame = frame; save()
    }

    var orderedTabs: [BrowserTab] {
        session.tabs.filter(\.isPinned)
            + session.tabs.filter { !$0.isPinned && $0.groupID == nil }
            + session.groups.flatMap { group in session.tabs.filter { $0.groupID == group.id } }
    }
    func cycleTab(_ offset: Int) {
        let tabs = orderedTabs
        guard let index = tabs.firstIndex(where: { $0.id == session.selectedTabID }) else { return }
        select(tabs[(index + offset + tabs.count) % tabs.count].id)
    }
}
