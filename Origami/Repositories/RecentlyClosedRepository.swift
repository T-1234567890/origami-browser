import Foundation
import GRDB

final class RecentlyClosedRepository {
    let database: DatabaseManager
    init(_ database: DatabaseManager) { self.database = database }
    func list(profileID: UUID, windowID: UUID) throws -> [(tab: BrowserTab, index: Int)] {
        try database.queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM recently_closed WHERE profile_id=? AND window_id=? ORDER BY closed_at LIMIT 20", arguments: [profileID.uuidString, windowID.uuidString]).compactMap { row in
                guard let id = UUID(uuidString: row["tab_id"]) else { return nil }
                let url = PersistedURL.clean((row["url"] as String?).flatMap(URL.init(string:)))
                guard let url, ["http", "https"].contains(url.scheme) else { return nil }
                return (BrowserTab(id: id, url: url, title: row["title"], isPinned: row["pinned"], groupID: (row["group_id"] as String?).flatMap(UUID.init(uuidString:))), row["position"])
            }
        }
    }
    static func replace(_ tabs: [(tab: BrowserTab, index: Int)], session: BrowserSession, in db: Database) throws {
        try db.execute(sql: "DELETE FROM recently_closed WHERE profile_id=? AND window_id=?", arguments: [session.profileID.uuidString, session.windowID.uuidString])
        for (order, closed) in tabs.filter({ $0.tab.canReopen }).suffix(20).enumerated() {
            let tab = closed.tab
            let url = PersistedURL.clean(tab.url)
            try db.execute(sql: "INSERT INTO recently_closed VALUES (?,?,?,?,?,?,?,?,?,?)", arguments: [UUID().uuidString, session.profileID.uuidString, session.windowID.uuidString, tab.id.uuidString, url?.absoluteString, url == nil ? "New Tab" : tab.title, tab.isPinned, tab.groupID?.uuidString, closed.index, Double(order)])
        }
    }
}
