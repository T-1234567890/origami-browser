import AppKit
import WebKit

extension BrowserStore {
    func handleInternal(_ method: String, params: [String: Any], tabID: UUID) async throws -> Any {
        guard let services, session.tabs.contains(where: { $0.id == tabID }) else { throw RepositoryError.invalidInput }
        let profileID = session.profileID
        func string(_ key: String) -> String { String((params[key] as? String ?? "").prefix(4096)) }
        func uuid(_ key: String) throws -> UUID { guard let id = UUID(uuidString: string(key)) else { throw RepositoryError.invalidInput }; return id }
        func folder() -> UUID? { UUID(uuidString: string("folderID")) }
        func offset() -> Int { min(max(params["offset"] as? Int ?? 0, 0), 1_000_000) }
        switch method {
        case "settings.read":
            let strict = try services.permissions.decision(.popups, origin: "*", profileID: profileID) == .block && services.permissions.decision(.autoplay, origin: "*", profileID: profileID) == .block
            return ["layout": session.layout.rawValue, "sidebarBehavior": sidebarBehavior.rawValue, "search": session.searchEngine.rawValue,
                    "braveSuggestions": preferences.braveSuggestions, "privateBraveSuggestions": preferences.privateBraveSuggestions,
                    "searchName": session.searchEngine.displayName, "restore": session.restoreSession,
                    "contentFrame": preferences.showContentFrame, "bookmarkBar": preferences.showBookmarkBar, "sleeping": preferences.automaticSleeping,
                    "askDownload": preferences.askDownloadDestination, "privacy": strict ? "strict" : "standard",
                    "profile": profileID.uuidString] as [String: Any]
        case "settings.write":
            guard let layoutText = params["layout"] as? String, let layout = TabLayout(rawValue: layoutText),
                  let searchText = params["search"] as? String, let search = SearchEngine(rawValue: searchText),
                  let restore = params["restore"] as? Bool else { throw RepositoryError.invalidInput }
            if let value = params["sidebarBehavior"] as? String {
                guard let behavior = SidebarBehavior(rawValue: value) else { throw RepositoryError.invalidInput }
                setSidebarBehavior(behavior)
            }
            setLayout(layout); setSearchEngine(search); setRestoreSession(restore)
            if let value = params["braveSuggestions"] as? Bool { preferences.braveSuggestions = value }
            if let value = params["privateBraveSuggestions"] as? Bool { preferences.privateBraveSuggestions = value }
            if let value = params["contentFrame"] as? Bool { preferences.showContentFrame = value }
            if let value = params["bookmarkBar"] as? Bool { preferences.showBookmarkBar = value }
            if let value = params["sleeping"] as? Bool { preferences.automaticSleeping = value }
            if let value = params["askDownload"] as? Bool { preferences.askDownloadDestination = value }
            if ["standard", "strict"].contains(string("privacy")) {
                preferences.privacy = string("privacy")
                try services.permissions.set(preferences.privacy == "strict" ? .block : .ask, category: .popups, origin: "*", profileID: profileID)
                try services.permissions.set(preferences.privacy == "strict" ? .block : .ask, category: .autoplay, origin: "*", profileID: profileID)
            }
            for store in application.map({ Array($0.stores.values) }) ?? [self] { store.preferencesRevision += 1 }
            return true
        case "navigation.open":
            guard let input = params["input"] as? String, let url = OmniboxRouter.destination(for: input, engine: session.searchEngine),
                  ["http", "https"].contains(url.scheme), let index = session.tabs.firstIndex(where: { $0.id == tabID }) else { throw RepositoryError.invalidInput }
            // Defer navigation until the current content action has returned.
            Task { @MainActor [weak self] in
                guard let self, self.session.tabs.indices.contains(index), self.session.tabs[index].id == tabID else { return }
                self.session.tabs[index].url = url; self.page(for: tabID).load(url); self.save()
            }
            return true
        case "onboarding.complete":
            preferences.onboardingComplete = true
            Task { @MainActor [weak self] in self?.page(for: tabID).load(InternalRoute.newTabURL) }
            return true
        case "history.list":
            var query = TimelineQuery()
            query.text = string("text"); query.domain = string("domain")
            query.since = params["since"] as? Double ?? 0; query.until = params["until"] as? Double ?? query.until
            query.beforeTime = params["beforeTime"] as? Double; query.beforeID = (params["beforeID"] as? NSNumber)?.int64Value ?? Int64.max
            return try services.history.timeline(profileID: profileID, query: query)
        case "history.delete":
            guard let id = params["id"] as? NSNumber else { throw RepositoryError.invalidInput }
            try services.history.deleteVisit(id.int64Value, profileID: profileID); return true
        case "history.clear":
            guard await confirm("Delete history in this date range for this profile?", tabID: tabID) else { return false }
            try services.history.clear(profileID: profileID, since: Date(timeIntervalSince1970: params["since"] as? Double ?? 0), until: Date(timeIntervalSince1970: params["until"] as? Double ?? Date.distantFuture.timeIntervalSince1970)); return true
        case "recent.list":
            return recentlyClosed.filter { $0.tab.canReopen }.reversed().prefix(20).map { ["id": $0.tab.id.uuidString, "title": $0.tab.title, "url": $0.tab.url?.absoluteString ?? ""] }
        case "recent.reopen":
            let id = try uuid("id")
            if let index = recentlyClosed.firstIndex(where: { $0.tab.id == id }) {
                var item = recentlyClosed.remove(at: index)
                if !session.groups.contains(where: { $0.id == item.tab.groupID }) { item.tab.groupID = nil }
                session.tabs.insert(item.tab, at: min(item.index, session.tabs.count)); select(id)
            }; return true
        case "windows.closed":
            guard let persistence else { return [] }
            return try SessionRepository(persistence.database).windows(closed: true).filter { $0.profileID == profileID && $0.tabs.contains(where: \.canReopen) }.prefix(20).map { ["id": $0.windowID.uuidString, "title": $0.tabs.first(where: \.canReopen)?.title ?? "Window", "count": $0.tabs.filter(\.canReopen).count] as [String: Any] }
        case "windows.reopen":
            guard let persistence, try SessionRepository(persistence.database).windows(closed: true).contains(where: { $0.windowID == (try? uuid("id")) && $0.profileID == profileID }) else { throw RepositoryError.wrongProfile }
            application?.reopenWindow(try uuid("id")); return true
        case "bookmarks.list":
            return try services.bookmarks.library(profileID: profileID, folderID: folder(), search: string("text"), offset: offset(), favorites: params["favorites"] as? Bool ?? false)
        case "bookmarks.folders":
            return try services.bookmarks.folders(profileID: profileID).map { ["id": $0.id.uuidString, "parentID": $0.parentID?.uuidString ?? "", "title": $0.title] }
        case "bookmarks.create":
            guard let url = URL(string: string("url")) else { throw RepositoryError.invalidInput }
            bookmarkRevision += 1
            return try services.bookmarks.addUnique(url: url, title: string("title"), folderID: folder(), profileID: profileID).uuidString
        case "bookmarks.edit":
            guard let url = URL(string: string("url")) else { throw RepositoryError.invalidInput }
            try services.bookmarks.edit(try uuid("id"), url: url, title: string("title"), folderID: folder(), favorite: params["favorite"] as? Bool ?? false, profileID: profileID)
            bookmarkRevision += 1; return true
        case "bookmarks.delete":
            try services.bookmarks.delete(try uuid("id"), profileID: profileID); bookmarkRevision += 1; return true
        case "bookmarks.reorder":
            try services.bookmarks.reorder(try uuid("id"), before: try uuid("before"), profileID: profileID); bookmarkRevision += 1; return true
        case "folders.create":
            bookmarkRevision += 1
            return try services.bookmarks.createFolder(title: string("title"), parentID: folder(), profileID: profileID).uuidString
        case "folders.edit":
            let id = try uuid("id")
            try services.bookmarks.moveFolder(id, parentID: folder(), position: params["position"] as? Int ?? 0, profileID: profileID)
            try services.bookmarks.renameFolder(id, title: string("title"), profileID: profileID); bookmarkRevision += 1; return true
        case "folders.delete":
            guard await confirm("Delete this folder and its bookmarks?", tabID: tabID) else { return false }
            try services.bookmarks.deleteFolder(try uuid("id"), profileID: profileID); bookmarkRevision += 1; return true
        case "folders.open":
            try openFolder(try uuid("id"), grouped: params["grouped"] as? Bool ?? false); return true
        case "bookmarks.import", "bookmarks.export", "downloads.directory":
            return try await fileAction(method, tabID: tabID)
        case "downloads.list":
            return try services.downloadRepository.list(profileID: profileID, offset: offset()).map {
                ["id": $0.id.uuidString, "filename": $0.filename, "url": $0.url, "state": $0.state.rawValue,
                 "received": $0.received, "expected": $0.expected ?? 0, "error": $0.error ?? ""] as [String: Any]
            }
        case "downloads.clear":
            try services.downloadRepository.clear(profileID: profileID, completedOnly: true); return true
        case "downloads.action":
            guard let record = try services.downloadRepository.list(profileID: profileID, id: try uuid("id")).first else { throw RepositoryError.invalidInput }
            switch string("action") {
            case "cancel": services.downloads.cancel(record.id)
            case "reveal": try services.downloads.reveal(record)
            case "open": try services.downloads.open(record)
            case "copy": NSPasteboard.general.clearContents(); NSPasteboard.general.setString(record.url, forType: .string)
            case "remove": try services.downloadRepository.remove(record.id, profileID: profileID)
            case "retry":
                guard let url = PersistedURL.clean(URL(string: record.url)), ["http", "https"].contains(url.scheme) else { throw RepositoryError.invalidInput }
                let download = await page(for: tabID).webView.startDownload(using: URLRequest(url: url))
                services.downloads.accept(download, profileID: profileID, tabID: tabID)
            default: throw RepositoryError.invalidInput
            }; return true
        case "data.list", "data.remove", "data.clear":
            guard let profile = try services.profiles.list().first(where: { $0.id == profileID }) else { throw RepositoryError.wrongProfile }
            if method == "data.list" {
                return await services.websiteData.records(profile: profile).map { ["name": $0.displayName, "types": Array($0.dataTypes).sorted()] as [String: Any] }
            }
            guard await confirm("Clear selected browsing data for “\(profile.name)”? This cannot be undone and may sign you out of websites.", tabID: tabID) else { return false }
            if method == "data.remove" {
                let names = Set(params["names"] as? [String] ?? [string("name")])
                guard !names.isEmpty, names.allSatisfy({ !$0.isEmpty && $0.count <= 4096 }) else { throw RepositoryError.invalidInput }
                let records = await services.websiteData.records(profile: profile).filter { names.contains($0.displayName) }
                let categories = Set(params["categories"] as? [String] ?? [string("type")])
                guard !categories.isEmpty, categories.isSubset(of: ["all", "cookies", "cache", "permissions"]) else { throw RepositoryError.invalidInput }
                let types = categories.contains("all") ? WKWebsiteDataStore.allWebsiteDataTypes() : Set(categories.compactMap { ClearBrowsingDataService.dataTypes[$0] })
                if !types.isEmpty { await services.websiteData.remove(records, types: types, profile: profile) }
                if categories.contains("permissions") {
                    for name in names.sorted() {
                        _ = try await handleInternal("data.resetPermissions", params: ["name": name], tabID: tabID)
                    }
                }
            } else {
                let range = string("range")
                let since: Date
                switch range {
                case "hour": since = Date().addingTimeInterval(-3600)
                case "today": since = Calendar.current.startOfDay(for: Date())
                case "week": since = Date().addingTimeInterval(-7 * 86400)
                case "all": since = .distantPast
                default: throw RepositoryError.invalidInput
                }
                try await ClearBrowsingDataService(services).clear(profile: profile, categories: Set(params["categories"] as? [String] ?? []), since: since)
            }; return true
        case "rules.list": return try services.permissions.rules(profileID: profileID)
        case "rules.set":
            try services.permissions.setSiteRule(string("rule"), value: params["value"] as? Bool ?? false, origin: string("origin"), profileID: profileID); return true
        case "data.resetPermissions":
            let name = string("name").lowercased()
            let choices = try services.permissions.choices(profileID: profileID)
            let origins = Set(choices.map(\.origin) + (try services.permissions.rules(profileID: profileID)).compactMap { $0["origin"] as? String } + (try services.externalProtocols.list(profileID: profileID)).compactMap { $0["origin"] })
            for origin in origins {
                if let host = URL(string: origin)?.host?.lowercased(), host == name || host.hasSuffix("." + name) {
                    try services.permissions.reset(profileID: profileID, origin: origin)
                }
            }; return true
        case "permissions.list":
            return try services.permissions.choices(profileID: profileID).map { ["origin": $0.origin, "category": $0.category, "decision": $0.decision] }
        case "permissions.set":
            guard let category = SitePermission(rawValue: string("category")), let decision = PermissionDecision(rawValue: string("decision")) else { throw RepositoryError.invalidInput }
            try services.permissions.set(decision, category: category, origin: string("origin"), profileID: profileID); return true
        case "permissions.reset":
            try services.permissions.reset(profileID: profileID, origin: string("origin")); return true
        case "profiles.list":
            return try services.profiles.list().map { ["id": $0.id.uuidString, "name": $0.name, "current": $0.id == profileID] as [String: Any] }
        case "profiles.create":
            guard !isPrivate else { throw RepositoryError.invalidInput }
            guard !string("name").trimmingCharacters(in: .whitespaces).isEmpty else { throw RepositoryError.invalidInput }
            return try services.profiles.create(name: String(string("name").prefix(80))).id.uuidString
        case "profiles.open":
            guard !isPrivate else { throw RepositoryError.invalidInput }
            let id = try uuid("id")
            guard try services.profiles.list().contains(where: { $0.id == id }) else { throw RepositoryError.wrongProfile }
            preferences.currentProfileID = id; _ = try application?.switchProfile(id, in: self); return true
        case "protocols.list": return try services.externalProtocols.list(profileID: profileID)
        case "protocols.set":
            guard let decision = PermissionDecision(rawValue: string("decision")) else { throw RepositoryError.invalidInput }
            try services.externalProtocols.set(decision, origin: string("origin"), scheme: string("scheme"), profileID: profileID); return true
        default: throw RepositoryError.invalidInput
        }
    }

}
