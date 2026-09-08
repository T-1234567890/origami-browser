import Foundation
import GRDB

final class AISearchRepository {
    let database: DatabaseManager
    init(_ database: DatabaseManager) { self.database = database }
    func save(_ event: AISearchEvent, profile: UUID, tab: UUID) throws {
        let data = try JSONEncoder().encode(event)
        try database.queue.write { db in
            try db.execute(sql: "INSERT INTO ai_search_events(id,profile_id,query,created,payload) VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload WHERE profile_id=excluded.profile_id", arguments: [event.id.uuidString, profile.uuidString, event.query, event.date.timeIntervalSince1970, data])
            try db.execute(sql: "INSERT INTO ai_answer_tabs(tab_id,event_id) VALUES(?,?) ON CONFLICT(tab_id) DO UPDATE SET event_id=excluded.event_id", arguments: [tab.uuidString, event.id.uuidString])
        }
    }
    func event(tab: UUID, profile: UUID) throws -> AISearchEvent? {
        try database.queue.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT e.payload FROM ai_search_events e JOIN ai_answer_tabs t ON t.event_id=e.id WHERE t.tab_id=? AND e.profile_id=?", arguments: [tab.uuidString, profile.uuidString]) else { return nil }
            return try JSONDecoder().decode(AISearchEvent.self, from: data)
        }
    }
    func list(profile: UUID) throws -> [AISearchEvent] {
        try database.queue.read { db in try Data.fetchAll(db, sql: "SELECT payload FROM ai_search_events WHERE profile_id=? ORDER BY created DESC LIMIT 200", arguments: [profile.uuidString]).compactMap { try? JSONDecoder().decode(AISearchEvent.self, from: $0) } }
    }
    func clear(profile: UUID, since: Date) throws {
        try database.queue.write { db in try db.execute(sql: "DELETE FROM ai_search_events WHERE profile_id=? AND created>=?", arguments: [profile.uuidString, since.timeIntervalSince1970]) }
    }
    func unlink(tab: UUID) throws { try database.queue.write { db in try db.execute(sql: "DELETE FROM ai_answer_tabs WHERE tab_id=?", arguments: [tab.uuidString]) } }
    func delete(_ ids: Set<UUID>, profile: UUID) throws {
        try database.queue.write { db in
            for id in ids { try db.execute(sql: "DELETE FROM ai_search_events WHERE id=? AND profile_id=?", arguments: [id.uuidString, profile.uuidString]) }
        }
    }
    func delete(_ id: UUID, profile: UUID) throws { try database.queue.write { db in try db.execute(sql: "DELETE FROM ai_search_events WHERE id=? AND profile_id=?", arguments: [id.uuidString, profile.uuidString]) } }
}
