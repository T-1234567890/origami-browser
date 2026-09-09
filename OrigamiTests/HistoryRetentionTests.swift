import Foundation
import Testing
import GRDB
@testable import Origami

@MainActor struct HistoryRetentionTests {
    @Test func preferenceDefaultsAndChoicesPersist() throws {
        let name = "Origami.retention." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = BrowserPreferences(defaults: defaults)
        #expect(preferences.historyRetentionDays == 90)
        for days in [30, 90, 180, 365, 0] {
            preferences.historyRetentionDays = days
            #expect(BrowserPreferences(defaults: defaults).historyRetentionDays == days)
        }
    }
    @Test func cleanupKeepsRecentActivityAndProtectedData() throws {
        let db = try DatabaseManager()
        let profiles = ProfileRepository(db)
        let profile = try profiles.ensureDefault(); let other = try profiles.create(name: "Second")
        let now = Date(); let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: now)!
        let old = cutoff.addingTimeInterval(-1)
        let history = HistoryRepository(db)
        for id in [profile.id, other.id] {
            try history.record(URL(string: "https://example.com/old")!, title: "Old", profileID: id, at: old)
            try history.record(URL(string: "https://example.com/keep")!, title: "Keep", profileID: id, at: old)
            try history.record(URL(string: "https://example.com/keep")!, title: "Keep", profileID: id, at: cutoff)
        }
        let repo = AISearchRepository(db)
        var expired = AISearchEvent(query: "Old", mode: .ask, action: .web, provider: .openRouter, model: "fixture")
        expired.date = old; expired.profileID = profile.id
        let expiredTab = UUID(); try repo.save(expired, profile: profile.id, tab: expiredTab)
        var active = expired; active.id = UUID()
        var follow = expired; follow.id = UUID(); follow.date = now
        active.explorations = [follow]
        let activeTab = UUID(); try repo.save(active, profile: profile.id, tab: activeTab)
        try db.queue.write { sql in
            try sql.execute(sql: "INSERT INTO bookmarks(id,profile_id,title,url,position,created_at) VALUES(?,?,?,?,0,?)", arguments: [UUID().uuidString, profile.id.uuidString, "Saved", "https://example.com", old.timeIntervalSince1970])
            try sql.execute(sql: "INSERT INTO permissions(profile_id,origin,category,decision) VALUES(?,?,?,?)", arguments: [profile.id.uuidString, "https://example.com", "camera", "allow"])
            try sql.execute(sql: "INSERT INTO downloads(id,profile_id,url,filename,state,created_at,updated_at) VALUES(?,?,?,?,?,?,?)", arguments: [UUID().uuidString, profile.id.uuidString, "https://example.com/a", "a.txt", "completed", old.timeIntervalSince1970, old.timeIntervalSince1970])
            try sql.execute(sql: "INSERT INTO recently_closed(id,profile_id,window_id,tab_id,title,pinned,position,closed_at) VALUES(?,?,?,?,?,0,0,?)", arguments: [UUID().uuidString, profile.id.uuidString, UUID().uuidString, UUID().uuidString, "Old tab", old.timeIntervalSince1970])
        }
        let cleaner = HistoryRetention(database: db)
        #expect(try cleaner.clean(days: 0, now: now).isEmpty)
        #expect(try history.list(profileID: profile.id).count == 3)
        #expect(try cleaner.clean(days: 90, now: now) == [expired.id])
        for id in [profile.id, other.id] { #expect(try history.list(profileID: id).count == 1) }
        #expect(try repo.event(tab: expiredTab, profile: profile.id) == nil)
        #expect(try repo.event(tab: activeTab, profile: profile.id) != nil)
        try db.queue.read { (sql: Database) throws -> Void in
            #expect(try Int.fetchOne(sql, sql: "SELECT COUNT(*) FROM recently_closed") == 0)
            for table in ["bookmarks", "permissions", "downloads"] {
                #expect(try Int.fetchOne(sql, sql: "SELECT COUNT(*) FROM " + table) == 1)
            }
            #expect(try Int.fetchOne(sql, sql: "SELECT MAX(visit_count) FROM history_pages") == 1)
        }
    }
    @Test func bulkDeleteRespectsProfileAndCascadesLinks() throws {
        let db = try DatabaseManager(); let profiles = ProfileRepository(db)
        let profile = try profiles.ensureDefault(); let other = try profiles.create(name: "Other")
        let repo = AISearchRepository(db)
        let one = AISearchEvent(query: "One", mode: .ask, action: .web, provider: .openRouter, model: "fixture")
        let two = AISearchEvent(query: "Two", mode: .ask, action: .web, provider: .openRouter, model: "fixture")
        let protected = AISearchEvent(query: "Other", mode: .ask, action: .web, provider: .openRouter, model: "fixture")
        try repo.save(one, profile: profile.id, tab: UUID()); try repo.save(two, profile: profile.id, tab: UUID())
        try repo.save(protected, profile: other.id, tab: UUID())
        try repo.delete(Set([one.id, two.id, protected.id]), profile: profile.id)
        #expect(try repo.list(profile: profile.id).isEmpty)
        #expect(try repo.list(profile: other.id).count == 1)
        #expect(try db.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ai_answer_tabs") } == 1)
    }
}
