import AppKit
import WebKit

extension BrowserStore {
    func openInternal(_ page: InternalPage) {
        if page == .settings, let tab = session.tabs.first(where: { $0.url.flatMap(InternalRoute.page(for:)) == .settings }) { select(tab.id); return }
        newTab(url: URL(string: "origami://\(page.rawValue)"))
    }
    func openAISettings() { settingsCategory = "AI"; openInternal(.settings) }
    func toggleBookmarkBar() { preferences.showBookmarkBar.toggle(); preferencesRevision += 1 }
    func bookmarkCurrentTab() {
        guard let tab = selectedTab, let url = tab.url, let services else { return }
        do { _ = try services.bookmarks.addUnique(url: url, title: tab.title, profileID: session.profileID); bookmarkRevision += 1 }
        catch { persistenceError = error.localizedDescription }
    }
    func bookmarkTabs(_ tabs: [BrowserTab], name: String) {
        guard let services else { return }
        do {
            let folder = try services.bookmarks.createFolder(title: name, profileID: session.profileID)
            for tab in tabs { if let url = tab.url, PersistedURL.clean(url) != nil { _ = try services.bookmarks.addUnique(url: url, title: tab.title, folderID: folder, profileID: session.profileID) } }
            bookmarkRevision += 1
        } catch { persistenceError = error.localizedDescription }
    }
    func openFolder(_ id: UUID, grouped: Bool = false) throws {
        guard let services else { return }
        let items = try services.bookmarks.folderBookmarks(id, profileID: session.profileID)
        guard items.count <= 200 else { throw RepositoryError.invalidInput }
        let group = grouped ? createGroup(name: try services.bookmarks.folders(profileID: session.profileID).first(where: { $0.id == id })?.title ?? "Bookmarks") : nil
        for bookmark in items { if let url = URL(string: bookmark.url) { newTab(url: url, groupID: group) } }
    }
    func sleep(_ id: UUID, automatic: Bool = false) async {
        guard let index = session.tabs.firstIndex(where: { $0.id == id }), !session.tabs[index].isPinned,
              (!automatic || (session.selectedTabID != id && session.split?.left != id && session.split?.right != id)), session.tabs[index].isSleeping != true,
              services?.downloads.hasActiveDownload(tabID: id) != true else { return }
        if let page = pages[id] {
            let inspectedURL = page.currentURL
            let state = await MediaStateService().sample(page.webView)
            let internalPage = page.nativePage != nil
            let playback = await page.webView.requestMediaPlaybackState()
            guard (internalPage || (!state.isPlayingMedia && !page.mediaState.isPlayingMedia && playback != .playing)), !state.hasCapture, !page.isLoading else { if !automatic { persistenceError = "This tab is loading, playing media or using capture. Stop that activity before sleeping it." }; return }
            let property = automatic ? "safeToSleep" : "canManuallySleep"
            let inspected = (try? await page.webView.evaluateJavaScript("window.__origamiActivity?.\(property) === true")) as? Bool ?? false
            let safe = internalPage || inspected
            guard safe else { if !automatic { persistenceError = "This page has unsaved input or an active connection, or its activity could not be checked. It has been kept awake." }; return }
            guard pages[id] === page, page.currentURL == inspectedURL, !page.isLoading, let currentTab = session.tabs.first(where: { $0.id == id }) else { return }
            if automatic, let services {
                var activity = page.activity
                activity.isPlayingMedia = state.isPlayingMedia; activity.hasCapture = state.hasCapture
                activity.hasDownload = services.downloads.hasActiveDownload(tabID: id); activity.backgroundActivityKnownSafe = safe
                guard services.lifecycle.maySleep(activity, pinned: currentTab.isPinned, selected: session.selectedTabID == id,
                                                  idleInterval: services.lifecycle.memoryPressure == .normal ? 900 : 300) else { return }
            }
        }
        guard let current = session.tabs.firstIndex(where: { $0.id == id }), (!automatic || (session.selectedTabID != id && session.split?.left != id && session.split?.right != id)),
              !session.tabs[current].isPinned, services?.downloads.hasActiveDownload(tabID: id) != true else { return }
        if let url = session.tabs[current].url, let origin = PermissionService.origin(url),
           (try? services?.permissions.siteRule("never_sleep", origin: origin, profileID: session.profileID)) == true {
            if !automatic { persistenceError = "This site is excluded from sleeping. Remove its Never Sleep exception in Website Permissions to sleep it." }
            return
        }
        pages.removeValue(forKey: id)?.dispose()
        session.tabs[current].isSleeping = true
        save()
    }
    func wake(_ id: UUID) {
        guard let index = session.tabs.firstIndex(where: { $0.id == id }) else { return }
        session.tabs[index].isSleeping = nil; save()
    }
    func neverSleep(_ tab: BrowserTab) {
        guard let url = tab.url, let origin = PermissionService.origin(url) else { return }
        do { try services?.permissions.setSiteRule("never_sleep", value: true, origin: origin, profileID: session.profileID) }
        catch { persistenceError = error.localizedDescription }
    }
    func startLifecycleMonitoring() {
        lifecycleTask?.cancel()
        lifecycleTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self, preferences.automaticSleeping else { continue }
                let threshold: TimeInterval = services?.lifecycle.memoryPressure == .normal ? 900 : 300
                for tab in session.tabs where tab.id != session.selectedTabID && !tab.isPinned && tab.isSleeping != true {
                    guard let page = pages[tab.id], Date().timeIntervalSince(page.activity.lastActive) >= threshold else { continue }
                    await sleep(tab.id, automatic: true)
                }
            }
        }
    }
    func confirm(_ message: String, tabID: UUID) async -> Bool {
        guard let page = pages[tabID] else { return false }
        if page.nativePage != nil {
            guard session.selectedTabID == tabID else { return false }
            resolveConfirmation(false)
            return await withCheckedContinuation { continuation in
                confirmationContinuation = continuation; confirmationMessage = message
            }
        }
        guard page.webView.window != nil else { return false }
        return await page.confirmAction(message)
    }
}
