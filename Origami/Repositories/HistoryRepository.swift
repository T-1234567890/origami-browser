import Foundation
import GRDB

struct HistoryVisit: Identifiable {
    let id: Int64
    let pageID: Int64
    let url: String
    let title: String
    let visitedAt: Date
}
final class HistoryRepository {
    let database: DatabaseManager
    init(_ database: DatabaseManager) { self.database = database }
    static func normalized(_ url: URL) -> URL? {
        guard let clean = PersistedURL.clean(url), ["http", "https"].contains(clean.scheme),
              var parts = URLComponents(url: clean, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = parts.scheme?.lowercased(); parts.host = parts.host?.lowercased(); parts.fragment = nil
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) { parts.port = nil }
        if parts.path.isEmpty { parts.path = "/" }
        return parts.url
    }
    func record(_ url: URL, title: String, profileID: UUID, at date: Date = Date()) throws {
        guard let normalized = Self.normalized(url), let raw = PersistedURL.clean(url) else { return }
        try database.queue.write { db in
            try db.execute(sql: """
              INSERT INTO history_pages(profile_id,normalized_url,url,title,host,first_seen,last_seen,visit_count)
              VALUES (?,?,?,?,?,?,?,1) ON CONFLICT(profile_id,normalized_url) DO UPDATE SET
              url=excluded.url,title=excluded.title,last_seen=MAX(last_seen,excluded.last_seen),first_seen=MIN(first_seen,excluded.first_seen),visit_count=visit_count+1
              """, arguments: [profileID.uuidString, normalized.absoluteString, raw.absoluteString, title, normalized.host ?? "", date.timeIntervalSince1970, date.timeIntervalSince1970])
            let pageID = try Int64.fetchOne(db, sql: "SELECT id FROM history_pages WHERE profile_id=? AND normalized_url=?", arguments: [profileID.uuidString, normalized.absoluteString])!
            try db.execute(sql: "INSERT INTO history_visits(page_id,profile_id,visited_at,transition) VALUES (?,?,?,?)", arguments: [pageID, profileID.uuidString, date.timeIntervalSince1970, "navigation"])
        }
    }
    func list(profileID: UUID, limit: Int = 100) throws -> [HistoryVisit] {
        try database.queue.read { db in
            try Row.fetchAll(db, sql: """
              SELECT v.id,v.page_id,p.url,p.title,v.visited_at FROM history_visits v JOIN history_pages p ON p.id=v.page_id
              WHERE v.profile_id=? ORDER BY v.visited_at DESC,v.id DESC LIMIT ?
              """, arguments: [profileID.uuidString, min(max(limit, 1), 500)]).map {
                HistoryVisit(id: $0["id"], pageID: $0["page_id"], url: $0["url"], title: $0["title"], visitedAt: Date(timeIntervalSince1970: $0["visited_at"]))
            }
        }
    }
    func delete(pageID: Int64, profileID: UUID) throws {
        try database.queue.write { try $0.execute(sql: "DELETE FROM history_pages WHERE id=? AND profile_id=?", arguments: [pageID, profileID.uuidString]) }
    }
}
