import Foundation
import GRDB

struct MigrationSelection {
    var bookmarks = true, history = true, tabs = true, search = false
}
enum MigrationWriter {
    /// Every destination write is inside one SQLite transaction; unavailable categories are untouched.
    static func apply(_ source: MigrationProfile, selection: MigrationSelection, database: DatabaseManager,
                      replacing current: BrowserSession? = nil) throws -> BrowserSession {
        let profileID = current?.profileID ?? UUID()
        var session = current ?? BrowserSession(); session.profileID = profileID
        if selection.tabs, let tabs = source.tabs {
            guard tabs.count <= 5000, tabs.allSatisfy({ MigrationInput.url($0.url.absoluteString) != nil }) else { throw MigrationFailure.invalid }
            var groups: [String: UUID] = [:]
            session.groups = []
            session.tabs = tabs.map { tab in
                if let name = tab.group, groups[name] == nil {
                    let group = TabGroup(name: name); groups[name] = group.id; session.groups.append(group)
                }
                return BrowserTab(url: tab.url, title: tab.title, isPinned: tab.pinned, groupID: tab.group.flatMap { groups[$0] }, isSleeping: true)
            }
            if session.tabs.isEmpty { session.tabs = [BrowserTab()] }
            session.split = nil; session.selectedTabID = session.tabs.first?.id; session.normalize()
        }
        if selection.search, let search = source.search.flatMap(SearchEngine.init(rawValue:)) { session.searchEngine = search }
        try database.queue.write { db in
            if current == nil {
                try db.execute(sql: "INSERT INTO profiles(id,name,created_at,website_store_id,color,sharing) VALUES (?,?,?,?,?,?)", arguments: [profileID.uuidString, String(source.name.prefix(80)), Date().timeIntervalSince1970, UUID().uuidString, "mint", try JSONEncoder().encode(ProfileSharing())])
            } else {
                guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM profiles WHERE id=?)", arguments: [profileID.uuidString]) == true else { throw MigrationFailure.invalid }
                // A replacement must never overwrite a shared category through another profile.
                let sharing = try Data.fetchOne(db, sql: "SELECT sharing FROM profiles WHERE id=?", arguments: [profileID.uuidString]).flatMap { try? JSONDecoder().decode(ProfileSharing.self, from: $0) } ?? ProfileSharing()
                if profileID != BrowserProfile.defaultID && ((selection.bookmarks && source.bookmarks != nil && sharing.bookmarks) || (selection.history && source.history != nil && sharing.history)) { throw MigrationFailure.sharedDestination }
                if profileID == BrowserProfile.defaultID {
                    for data in try Data.fetchAll(db, sql: "SELECT sharing FROM profiles WHERE id<>? AND sharing IS NOT NULL", arguments: [profileID.uuidString]) {
                        let sharing = try JSONDecoder().decode(ProfileSharing.self, from: data)
                        if (selection.bookmarks && source.bookmarks != nil && sharing.bookmarks) || (selection.history && source.history != nil && sharing.history) { throw MigrationFailure.sharedDestination }
                    }
                }
            }
            if selection.bookmarks, let bookmarks = source.bookmarks {
                try db.execute(sql: "DELETE FROM bookmarks WHERE profile_id=?", arguments: [profileID.uuidString])
                try db.execute(sql: "DELETE FROM bookmark_folders WHERE profile_id=?", arguments: [profileID.uuidString])
                var count = 0
                func insert(_ items: [MigrationBookmark], parent: UUID?, depth: Int) throws {
                    guard depth < 32 else { throw MigrationFailure.tooLarge }
                    for (position, item) in items.enumerated() {
                        count += 1; guard count <= 100000 else { throw MigrationFailure.tooLarge }
                        let id = UUID()
                        if let url = item.url {
                            guard MigrationInput.url(url.absoluteString) != nil else { throw MigrationFailure.invalid }
                            try db.execute(sql: "INSERT INTO bookmarks(id,profile_id,folder_id,title,url,position,created_at) VALUES (?,?,?,?,?,?,?)", arguments: [id.uuidString, profileID.uuidString, parent?.uuidString, item.title, url.absoluteString, position, Date().timeIntervalSince1970])
                        } else {
                            try db.execute(sql: "INSERT INTO bookmark_folders VALUES (?,?,?,?,?)", arguments: [id.uuidString, profileID.uuidString, parent?.uuidString, item.title, position])
                            try insert(item.children, parent: id, depth: depth + 1)
                        }
                    }
                }
                try insert(bookmarks, parent: nil, depth: 0)
            }
            if selection.history, let visits = source.history {
                guard visits.count <= 100000 else { throw MigrationFailure.tooLarge }
                try db.execute(sql: "DELETE FROM history_pages WHERE profile_id=?", arguments: [profileID.uuidString])
                for visit in visits {
                    guard let url = HistoryRepository.normalized(visit.url), visit.date.timeIntervalSince1970.isFinite else { throw MigrationFailure.invalid }
                    try db.execute(sql: """
                        INSERT INTO history_pages(profile_id,normalized_url,url,title,host,first_seen,last_seen,visit_count) VALUES (?,?,?,?,?,?,?,1)
                        ON CONFLICT(profile_id,normalized_url) DO UPDATE SET visit_count=visit_count+1,first_seen=MIN(first_seen,excluded.first_seen),last_seen=MAX(last_seen,excluded.last_seen)
                        """, arguments: [profileID.uuidString, url.absoluteString, visit.url.absoluteString, visit.title, url.host ?? "", visit.date.timeIntervalSince1970, visit.date.timeIntervalSince1970])
                    let id = try Int64.fetchOne(db, sql: "SELECT id FROM history_pages WHERE profile_id=? AND normalized_url=?", arguments: [profileID.uuidString, url.absoluteString])!
                    try db.execute(sql: "INSERT INTO history_visits(page_id,profile_id,visited_at,transition) VALUES (?,?,?,?)", arguments: [id, profileID.uuidString, visit.date.timeIntervalSince1970, "import"])
                }
            }
            if current == nil || (selection.tabs && source.tabs != nil) {
                if current != nil {
                    try db.execute(sql: "DELETE FROM browser_sessions WHERE profile_id=?", arguments: [profileID.uuidString])
                    try db.execute(sql: "DELETE FROM recently_closed WHERE profile_id=?", arguments: [profileID.uuidString])
                }
                try SessionRepository(database).write(session, recentlyClosed: [], in: db)
            }
        }
        return session
    }
}

extension BrowserStore {
    @discardableResult func importBrowserProfile(_ profile: MigrationProfile, selection: MigrationSelection, replace: Bool, openImported: Bool = true) throws -> BrowserSession {
        guard !isPrivate, let services, let application else { throw MigrationFailure.invalid }
        if replace, application.stores.values.filter({ !$0.isPrivate && $0.session.profileID == session.profileID }).count > 1 { throw MigrationFailure.destinationOpen }
        let imported = try MigrationWriter.apply(profile, selection: selection, database: services.profiles.database, replacing: replace ? session : nil)
        if selection.search, let engine = profile.search.flatMap(SearchEngine.init(rawValue:)) {
            preferences.searchEngine = engine
            for store in application.stores.values { store.session.searchEngine = engine; store.preferencesRevision += 1 }
        }
        if replace {
            if selection.tabs && profile.tabs != nil {
                dismissPeek(); resolveConfirmation(false)
                for page in pages.values { page.dispose() }
                pages.removeAll(); recentlyClosed.removeAll()
                session = imported
            }
            bookmarksChanged(); save()
        } else if openImported { _ = application.openImportedSession(imported) }
        else { application.profileRevision += 1 }
        NotificationCenter.default.post(name: .origamiHistoryChanged, object: nil)
        return imported
    }
}
