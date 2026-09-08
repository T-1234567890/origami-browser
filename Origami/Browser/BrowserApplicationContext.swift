import SwiftUI
import AppKit
import WebKit

@MainActor @Observable
final class BrowserApplicationContext {
    let persistence: SessionStore?
    let services: BrowserServices?
    private(set) var stores: [UUID: BrowserStore] = [:]
    private(set) var initialID = UUID()
    var activeID: UUID?
    @ObservationIgnored var globalControls: GlobalBrowserControls?
    func startGlobalControls() { if globalControls == nil { globalControls = GlobalBrowserControls(application: self) } }
    var quitting = false
    var profileRevision = 0
    @ObservationIgnored var states: [UUID: BrowserWindowState] = [:]
    @ObservationIgnored var openWindow: ((UUID) -> Void)?
    var activeStore: BrowserStore? { states.first(where: { $0.value.isKey }).flatMap { stores[$0.key] } ?? activeID.flatMap { stores[$0] } }
    init(isolated: Bool = false, sessionStore: SessionStore? = nil) {
        persistence = sessionStore ?? (isolated ? nil : SessionStore())
        var initial: BrowserSession?
        var restored: [BrowserSession] = []
        var initializationError: String?
        var initializedServices: BrowserServices?
        do {
            initial = try persistence?.load()
            let db = try persistence?.database ?? DatabaseManager()
            initializedServices = try BrowserServices(database: db, preferences: persistence?.preferences)
            // Launch one window. Other profile sessions remain available for explicit switching.
        } catch {
            initializationError = error.localizedDescription
        }
        services = initializedServices
        if restored.isEmpty { restored = [initial ?? BrowserSession()] }
        var needsWelcome = !isolated && persistence?.preferences.onboardingComplete == false
        for var session in restored {
            persistence?.preferences.apply(to: &session)
            if needsWelcome { needsWelcome = false; if !session.tabs.contains(where: { $0.url?.host == "welcome" && $0.url?.scheme == "origami" }) { let welcome = BrowserTab(url: URL(string: "origami://welcome")); session.tabs.insert(welcome, at: 0); session.selectedTabID = welcome.id } }
            session.normalize()
            let store = BrowserStore(session: session, persistence: persistence, services: services)
            store.persistenceError = initializationError
            stores[session.windowID] = store
        }
        initialID = restored.first!.windowID
        for store in stores.values { store.application = self }
        // Repair older sessions that allowed six pins per window instead of per profile.
        var counts: [UUID: Int] = [:]
        for store in stores.values.sorted(by: { $0.session.windowID.uuidString < $1.session.windowID.uuidString }) {
            for index in store.session.tabs.indices where store.session.tabs[index].isPinned {
                let profile = store.session.profileID
                if counts[profile, default: 0] < BrowserSession.maximumPinnedTabs { counts[profile, default: 0] += 1 }
                else { store.session.tabs[index].isPinned = false }
            }
        }
        services?.downloads.onError = { [weak self] in self?.activeStore?.persistenceError = $0 }
        services?.downloads.windowForTab = { [weak self] id in
            self?.stores.values.first(where: { $0.session.tabs.contains(where: { $0.id == id }) })?.nativeWindow
        }
    }
    func resolve(_ id: UUID?) -> BrowserStore {
        let id = id ?? initialID
        if let store = stores[id] { return store }
        var session = BrowserSession(); session.windowID = id
        session.profileID = persistence?.preferences.currentProfileID ?? BrowserProfile.defaultID
        return install(session)
    }
    private func install(_ session: BrowserSession) -> BrowserStore {
        var session = session
        persistence?.preferences.apply(to: &session)
        let store = BrowserStore(session: session, persistence: persistence, services: services)
        store.application = self; stores[session.windowID] = store
        store.save()
        return store
    }
    @discardableResult func newWindow(profileID: UUID? = nil) -> BrowserStore {
        var session = BrowserSession()
        session.profileID = profileID ?? activeStore?.session.profileID ?? BrowserProfile.defaultID
        let store = install(session)
        openWindow?(session.windowID)
        return store
    }
    @discardableResult func newPrivateWindow(profileID: UUID? = nil) -> BrowserStore? {
        do {
            guard let services else { throw RepositoryError.invalidInput }
            let id = profileID ?? activeStore?.session.profileID ?? BrowserProfile.defaultID
            guard let profile = try services.profiles.list().first(where: { $0.id == id }) else { throw RepositoryError.wrongProfile }
            let preferences = persistence?.preferences ?? activeStore?.preferences ?? BrowserPreferences()
            let privateServices = try BrowserServices(database: DatabaseManager(), preferences: preferences,
                                                      privateProfile: profile, sharedBookmarks: services.bookmarks)
            var session = BrowserSession(); session.profileID = id
            preferences.apply(to: &session)
            let store = BrowserStore(session: session, services: privateServices, preferences: preferences)
            store.application = self; stores[session.windowID] = store
            privateServices.downloads.onError = { [weak store] in store?.persistenceError = $0 }
            privateServices.downloads.windowForTab = { [weak store] _ in store?.nativeWindow }
            openWindow?(session.windowID)
            return store
        } catch { activeStore?.persistenceError = "The private window could not be opened. " + error.localizedDescription; return nil }
    }
    /// Switching identities focuses or restores that profile's own window; WebViews never cross stores.
    @discardableResult func switchProfile(_ id: UUID, in source: BrowserStore? = nil) throws -> BrowserStore {
        guard try services?.profiles.list().contains(where: { $0.id == id }) == true else { throw RepositoryError.wrongProfile }
        if let source { return try replaceProfile(id, in: source) }
        persistence?.preferences.currentProfileID = id
        if let existing = stores.values.first(where: { !$0.isPrivate && $0.session.profileID == id }) {
            activeID = existing.session.windowID
            if let window = existing.nativeWindow { window.makeKeyAndOrderFront(nil) }
            else { openWindow?(existing.session.windowID) }
            return existing
        }
        if let persistence {
            let repo = SessionRepository(try persistence.database)
            if let session = try repo.load(profileID: id) ?? repo.windows(closed: true).first(where: { $0.profileID == id }) {
                let store = install(session); activeID = session.windowID; openWindow?(session.windowID); return store
            }
        }
        let store = newWindow(profileID: id); activeID = store.session.windowID; return store
    }
    /// Replace a window's identity context without moving WebViews between profiles.
    private func replaceProfile(_ id: UUID, in source: BrowserStore) throws -> BrowserStore {
        guard !source.isPrivate, stores[source.session.windowID] === source, let services else { throw RepositoryError.wrongProfile }
        if source.session.profileID == id { return source }
        let repository = SessionRepository(services.profiles.database)
        try repository.save(source.session, recentlyClosed: source.recentlyClosed)
        // A session already displayed in another window must never be mounted twice.
        let saved = try (repository.windows() + repository.windows(closed: true)).first {
            $0.profileID == id && stores[$0.windowID] == nil
        }
        var session = saved ?? BrowserSession()
        session.profileID = id
        session.windowFrame = source.session.windowFrame
        source.preferences.apply(to: &session)
        session.normalize()
        let replacement = BrowserStore(session: session, persistence: persistence, services: services, preferences: source.preferences)
        try repository.save(replacement.session, recentlyClosed: replacement.recentlyClosed)
        try repository.closeWindow(source.session.windowID)

        source.dismissPeek()
        source.lifecycleTask?.cancel()
        source.resolveConfirmation(false)
        source.pages.values.forEach { $0.dispose() }
        source.pages.removeAll()
        let state = states.removeValue(forKey: source.session.windowID)
        stores.removeValue(forKey: source.session.windowID)
        replacement.application = self
        stores[session.windowID] = replacement
        if let state {
            states[session.windowID] = state
            state.showingPreferences = false
            state.profileStore = replacement
        }
        if initialID == source.session.windowID { initialID = session.windowID }
        activeID = session.windowID
        source.preferences.currentProfileID = id
        replacement.startLifecycleMonitoring()
        return replacement
    }

    func deleteProfile(_ id: UUID) async throws {
        guard id != BrowserProfile.defaultID, let services,
              let profile = try services.profiles.list().first(where: { $0.id == id }) else { throw RepositoryError.invalidInput }
        let affected = stores.values.filter { $0.session.profileID == id }
        for store in affected {
            let window = store.nativeWindow
            close(store.session.windowID)
            window?.close()
        }
        services.downloads.cancel(profileID: id)
        await services.websiteData.clear(profile: profile)
        try services.profiles.delete(id)
        profileRevision += 1
        if persistence?.preferences.currentProfileID == id { persistence?.preferences.currentProfileID = BrowserProfile.defaultID }
        _ = try switchProfile(BrowserProfile.defaultID)
    }

    func close(_ id: UUID) {
        guard !quitting || stores[id]?.isPrivate == true else { stores[id]?.save(); return }
        stores[id]?.save()
        do { if stores[id]?.isPrivate != true, let persistence { try SessionRepository(persistence.database).closeWindow(id) } }
        catch { activeStore?.persistenceError = error.localizedDescription }
        if stores[id]?.isPrivate == true {
            stores[id]?.services?.downloads.cancelAll()
            stores[id]?.services?.feeds.cancelAll()
            if let store = stores[id], let data = try? store.services?.websiteStore(profileID: store.session.profileID) {
                Task { await data.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) }
            }
        }
        if let store = stores[id] { for tab in store.session.tabs { store.services?.ai.release(tab.id) }; if store.isPrivate { store.services?.ai.stop() } }
        stores[id]?.dismissPeek()
        stores[id]?.lifecycleTask?.cancel()
        stores[id]?.resolveConfirmation(false)
        stores[id]?.pages.values.forEach { $0.dispose() }
        stores[id]?.pages.removeAll()
        stores.removeValue(forKey: id); states.removeValue(forKey: id)
        if activeID == id { activeID = stores.keys.first }
    }
    func reopenWindow(_ id: UUID? = nil) {
        do {
            guard let persistence, let session = try SessionRepository(persistence.database).windows(closed: true).first(where: { id == nil || $0.windowID == id }) else { return }
            _ = install(session); openWindow?(session.windowID)
        } catch { activeStore?.persistenceError = error.localizedDescription }
    }
    func moveTab(_ tabID: UUID, from source: BrowserStore, to target: BrowserStore) {
        guard source !== target, !source.isPrivate, !target.isPrivate, source.session.profileID == target.session.profileID,
              let index = source.session.tabs.firstIndex(where: { $0.id == tabID }) else { return }
        var nextSource = source.session, nextTarget = target.session
        var tab = nextSource.tabs.remove(at: index); tab.groupID = nil
        nextSource.normalize()
        nextTarget.tabs.append(tab); nextTarget.selectedTabID = tabID; nextTarget.normalize()
        do {
            if let persistence { try SessionRepository(persistence.database).transfer(source: nextSource, sourceClosed: source.recentlyClosed, target: nextTarget, targetClosed: target.recentlyClosed) }
        } catch { source.persistenceError = "The tab could not be moved: \(error.localizedDescription)"; return }
        let retained = source.pages.removeValue(forKey: tabID)
        source.session = nextSource; target.session = nextTarget
        if let retained { target.bind(retained, to: tabID); target.pages[tabID] = retained }
        target.select(tabID)
    }
}
