import Foundation
import GRDB

struct TimelineQuery {
    var text = ""
    var domain = ""
    var since: Double = 0
    var until: Double = Date.distantFuture.timeIntervalSince1970
    var beforeTime: Double?
    var beforeID: Int64 = Int64.max
    var limit = 100
}
extension HistoryRepository {
    func timeline(profileID: UUID, query: TimelineQuery) throws -> [[String: Any]] {
        try database.queue.read { db in
            try Row.fetchAll(db, sql: """
            SELECT v.id,v.page_id,v.visited_at,p.url,p.title,p.host,p.visit_count
            FROM history_visits v JOIN history_pages p ON p.id=v.page_id
            WHERE v.profile_id=? AND v.visited_at>=? AND v.visited_at<?
              AND (?='' OR p.title LIKE ? ESCAPE '\\' OR p.url LIKE ? ESCAPE '\\')
              AND (?='' OR p.host=? OR p.host LIKE ? ESCAPE '\\')
              AND (v.visited_at<? OR (v.visited_at=? AND v.id<?))
            ORDER BY v.visited_at DESC,v.id DESC LIMIT ?
            """, arguments: [profileID.uuidString, query.since, query.until,
                             query.text, "%" + Self.escapeLike(query.text) + "%", "%" + Self.escapeLike(query.text) + "%",
                             query.domain, query.domain.lowercased(), "%." + Self.escapeLike(query.domain.lowercased()),
                             query.beforeTime ?? query.until, query.beforeTime ?? query.until, query.beforeID, min(max(query.limit, 1), 100)]).map {
                ["id": $0["id"] as Int64, "pageID": $0["page_id"] as Int64, "time": $0["visited_at"] as Double,
                 "url": $0["url"] as String, "title": $0["title"] as String, "host": $0["host"] as String, "visits": $0["visit_count"] as Int]
            }
        }
    }
    static func escapeLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }
    func deleteVisit(_ id: Int64, profileID: UUID) throws {
        try database.queue.write { db in
            try db.execute(sql: "DELETE FROM history_visits WHERE id=? AND profile_id=?", arguments: [id, profileID.uuidString])
            try Self.recount(profileID, db: db)
        }
    }
    func clear(profileID: UUID, since: Date, until: Date = .distantFuture) throws {
        try database.queue.write { db in
            try db.execute(sql: "DELETE FROM history_visits WHERE profile_id=? AND visited_at>=? AND visited_at<?", arguments: [profileID.uuidString, since.timeIntervalSince1970, until.timeIntervalSince1970])
            try Self.recount(profileID, db: db)
        }
    }
    private static func recount(_ profile: UUID, db: Database) throws {
        try db.execute(sql: "DELETE FROM history_pages WHERE profile_id=? AND NOT EXISTS(SELECT 1 FROM history_visits WHERE page_id=history_pages.id)", arguments: [profile.uuidString])
        try db.execute(sql: """
        UPDATE history_pages SET visit_count=(SELECT COUNT(*) FROM history_visits WHERE page_id=history_pages.id),
        first_seen=(SELECT MIN(visited_at) FROM history_visits WHERE page_id=history_pages.id),
        last_seen=(SELECT MAX(visited_at) FROM history_visits WHERE page_id=history_pages.id) WHERE profile_id=?
        """, arguments: [profile.uuidString])
    }
}
