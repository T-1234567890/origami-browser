import Foundation
import GRDB

final class SessionRepository {
    let database: DatabaseManager
    init(_ database: DatabaseManager) { self.database = database }
    func load(profileID: UUID, windowID requestedWindowID: UUID? = nil) throws -> BrowserSession? {
        try database.queue.read { db in
            guard let window = try Row.fetchOne(db, sql: """
                SELECT w.*, s.profile_id FROM windows w JOIN browser_sessions s ON s.id=w.session_id
                WHERE s.profile_id=? AND (? IS NULL OR w.id=?) AND (? IS NOT NULL OR w.closed_at IS NULL) ORDER BY w.closed_at IS NOT NULL,s.updated_at DESC, w.position LIMIT 1
                """, arguments: [profileID.uuidString, requestedWindowID?.uuidString, requestedWindowID?.uuidString, requestedWindowID?.uuidString]),
                  let windowID = UUID(uuidString: window["id"]), let sessionID = UUID(uuidString: window["session_id"]) else { return nil }
            var session = BrowserSession()
            session.id = sessionID; session.windowID = windowID; session.profileID = profileID
            session.windowFrame = window["frame"]
            if let left = (window["split_left"] as String?).flatMap(UUID.init(uuidString:)),
               let right = (window["split_right"] as String?).flatMap(UUID.init(uuidString:)) {
                session.split = BrowserSplit(left: left, right: right)
            }
            session.selectedTabID = (window["selected_tab_id"] as String?).flatMap(UUID.init(uuidString:))
            session.groups = try Row.fetchAll(db, sql: "SELECT * FROM tab_groups WHERE window_id=? ORDER BY position", arguments: [windowID.uuidString]).compactMap { row in
                guard let id = UUID(uuidString: row["id"]) else { return nil }
                return TabGroup(id: id, name: row["name"], isCollapsed: row["collapsed"], color: (row["color"] as String?).flatMap(TabGroupColor.init(rawValue:)), anchorIndex: row["anchor_index"])
            }
            session.tabs = try Row.fetchAll(db, sql: "SELECT * FROM tabs WHERE window_id=? ORDER BY position", arguments: [windowID.uuidString]).compactMap { row in
                guard let id = UUID(uuidString: row["id"]) else { return nil }
                let url = PersistedURL.clean((row["url"] as String?).flatMap(URL.init(string:)))
                return BrowserTab(id: id, url: url, title: url == nil ? "New Tab" : row["title"], isPinned: row["pinned"],
                                  groupID: (row["group_id"] as String?).flatMap(UUID.init(uuidString:)), isSleeping: (row["sleeping"] as Bool) ? true : nil)
            }
            session.normalize()
            return session
        }
    }
    func windows(closed: Bool = false) throws -> [BrowserSession] {
        let identities: [(UUID, UUID)] = try database.queue.read { db in
            try Row.fetchAll(db, sql: "SELECT w.id,s.profile_id FROM windows w JOIN browser_sessions s ON s.id=w.session_id WHERE w.closed_at IS \(closed ? "NOT NULL" : "NULL") ORDER BY w.closed_at DESC,w.position").compactMap {
                guard let window = UUID(uuidString: $0["id"]), let profile = UUID(uuidString: $0["profile_id"]) else { return nil }
                return (window, profile)
            }
        }
        return try identities.compactMap { try load(profileID: $0.1, windowID: $0.0) }
    }
    func closeWindow(_ id: UUID) throws {
        try database.queue.write { try $0.execute(sql: "UPDATE windows SET closed_at=? WHERE id=?", arguments: [Date().timeIntervalSince1970, id.uuidString]) }
    }
    func save(_ session: BrowserSession, recentlyClosed: [(tab: BrowserTab, index: Int)] = []) throws {
        try database.queue.write { try write(session, recentlyClosed: recentlyClosed, in: $0) }
    }
    func transfer(source: BrowserSession, sourceClosed: [(tab: BrowserTab, index: Int)], target: BrowserSession, targetClosed: [(tab: BrowserTab, index: Int)]) throws {
        guard source.profileID == target.profileID, source.windowID != target.windowID else { throw RepositoryError.wrongProfile }
        try database.queue.write { db in
            try write(source, recentlyClosed: sourceClosed, in: db)
            try write(target, recentlyClosed: targetClosed, in: db)
        }
    }
    private func write(_ session: BrowserSession, recentlyClosed: [(tab: BrowserTab, index: Int)], in db: Database) throws {
        try db.execute(sql: "INSERT INTO browser_sessions VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET updated_at=excluded.updated_at", arguments: [session.id.uuidString, session.profileID.uuidString, Date().timeIntervalSince1970])
        try db.execute(sql: "INSERT INTO windows(id,session_id,selected_tab_id,frame) VALUES (?,?,?,?) ON CONFLICT(id) DO UPDATE SET selected_tab_id=excluded.selected_tab_id,frame=excluded.frame,closed_at=NULL", arguments: [session.windowID.uuidString, session.id.uuidString, session.selectedTabID?.uuidString, session.windowFrame])
        try db.execute(sql: "UPDATE windows SET split_left=?,split_right=? WHERE id=?", arguments: [session.split?.left.uuidString, session.split?.right.uuidString, session.windowID.uuidString])
        try db.execute(sql: "DELETE FROM tabs WHERE window_id=?", arguments: [session.windowID.uuidString])
        try db.execute(sql: "DELETE FROM tab_groups WHERE window_id=?", arguments: [session.windowID.uuidString])
        for (position, group) in session.groups.enumerated() {
            try db.execute(sql: "INSERT INTO tab_groups(id,window_id,name,collapsed,position,color,anchor_index) VALUES (?,?,?,?,?,?,?)", arguments: [group.id.uuidString, session.windowID.uuidString, group.name, group.isCollapsed, position, group.color?.rawValue, group.anchorIndex])
        }
        for (position, tab) in session.tabs.enumerated() {
            let url = PersistedURL.clean(tab.url)
            try db.execute(sql: "INSERT INTO tabs(id,window_id,group_id,url,title,pinned,position,sleeping) VALUES (?,?,?,?,?,?,?,?)", arguments: [tab.id.uuidString, session.windowID.uuidString, tab.groupID?.uuidString, url?.absoluteString, url == nil ? "New Tab" : tab.title, tab.isPinned, position, tab.isSleeping == true])
        }
        try RecentlyClosedRepository.replace(recentlyClosed, session: session, in: db)
    }
}

enum PersistedURL {
    static func clean(_ url: URL?) -> URL? {
        guard let url else { return nil }
        if InternalRoute.page(for: url) != nil { return url }
        guard ["http", "https"].contains(url.scheme?.lowercased()), url.host?.isEmpty == false,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.user = nil; components.password = nil
        return components.url
    }
}
