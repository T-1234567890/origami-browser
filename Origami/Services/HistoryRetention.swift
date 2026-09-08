import Foundation
import GRDB

extension Notification.Name { static let origamiHistoryChanged = Notification.Name("Origami.historyChanged") }

/// Only history tables are touched. Website stores, credentials, files and bookmarks are outside this service.
struct HistoryRetention {
    let database: DatabaseManager
    func clean(days: Int, now: Date = Date(), keeping: Set<UUID> = []) throws -> Set<UUID> {
        guard days > 0, let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) else { return [] }
        return try database.queue.write { db in
            let timestamp = cutoff.timeIntervalSince1970
            try db.execute(sql: "DELETE FROM history_visits WHERE visited_at < ?", arguments: [timestamp])
            try db.execute(sql: "DELETE FROM history_pages WHERE NOT EXISTS(SELECT 1 FROM history_visits WHERE page_id=history_pages.id)")
            try db.execute(sql: """
                UPDATE history_pages SET visit_count=(SELECT COUNT(*) FROM history_visits WHERE page_id=history_pages.id),
                first_seen=(SELECT MIN(visited_at) FROM history_visits WHERE page_id=history_pages.id),
                last_seen=(SELECT MAX(visited_at) FROM history_visits WHERE page_id=history_pages.id)
                """)
            try db.execute(sql: "DELETE FROM recently_closed WHERE closed_at < ?", arguments: [timestamp])
            var removed = Set<UUID>()
            for row in try Row.fetchAll(db, sql: "SELECT id,payload FROM ai_search_events WHERE created < ?", arguments: [timestamp]) {
                let raw: String = row["id"]
                guard let id = UUID(uuidString: raw), !keeping.contains(id) else { continue }
                let data: Data = row["payload"]
                // Preserve unknown/corrupt formats; do not guess their most recent activity.
                guard let event = try? JSONDecoder().decode(AISearchEvent.self, from: data), event.latestActivity < cutoff else { continue }
                try db.execute(sql: "DELETE FROM ai_search_events WHERE id=?", arguments: [raw]); removed.insert(id)
            }
            return removed
        }
    }
}
extension AISearchEvent {
    var latestActivity: Date {
        ([date] + (explorations ?? []).map(\.latestActivity) + (versions ?? []).map(\.latestActivity)).max() ?? date
    }
}
