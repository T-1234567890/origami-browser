import Foundation
import GRDB
import Observation

enum HighlightStyle: String, Codable, CaseIterable, Identifiable {
    case yellow, mint, lavender
    var id: Self { self }
    var title: String { rawValue.capitalized }
}

/// Paths and offsets are hints; the quote and surrounding context verify the destination.
struct HighlightAnchor: Codable, Equatable {
    var text: String
    var prefix: String
    var suffix: String
    var startPath: [Int]
    var endPath: [Int]
    var startOffset: Int
    var endOffset: Int
    var position: Int
    var valid: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf16.count <= 8000 &&
        prefix.utf16.count <= 64 && suffix.utf16.count <= 64 &&
        startPath.count <= 64 && endPath.count <= 64 &&
        (startPath + endPath).allSatisfy { (0...10000).contains($0) } &&
        (0...200000).contains(startOffset) && (0...200000).contains(endOffset) && (0...200000).contains(position)
    }
}
struct HighlightRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var url: String
    var pageTitle: String
    var anchor: HighlightAnchor
    var style: HighlightStyle
    var createdAt = Date()
    var schemaVersion = 1
}

final class HighlightStore {
    let database: DatabaseManager
    init(database: DatabaseManager) { self.database = database }
    // Keep content-identifying queries and SPA fragments. Never accept embedded credentials.
    static func pageKey(_ url: URL) -> String? {
        guard ["https", "http"].contains(url.scheme), url.host != nil,
              url.user == nil, url.password == nil, url.absoluteString.utf8.count <= 8192 else { return nil }
        return url.absoluteString
    }
    func records(url: URL, profile: UUID) throws -> [HighlightRecord] {
        guard let key = Self.pageKey(url) else { return [] }
        return try database.queue.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM web_highlights WHERE profile_id=? AND url=? ORDER BY created,id LIMIT 200", arguments: [profile.uuidString, key])
                .map { try JSONDecoder().decode(HighlightRecord.self, from: $0) }
        }
    }
    func save(_ record: HighlightRecord, profile: UUID) throws {
        guard record.schemaVersion == 1, record.anchor.valid, record.pageTitle.count <= 300,
              let url = URL(string: record.url), Self.pageKey(url) == record.url else { throw RepositoryError.invalidInput }
        let data = try JSONEncoder().encode(record)
        try database.queue.write { db in
            let existing = try String.fetchOne(db, sql: "SELECT url FROM web_highlights WHERE id=? AND profile_id=?", arguments: [record.id.uuidString, profile.uuidString])
            guard existing == nil || existing == record.url else { throw RepositoryError.invalidInput }
            if existing == nil {
                let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM web_highlights WHERE profile_id=? AND url=?", arguments: [profile.uuidString, record.url]) ?? 0
                guard count < 200 else { throw RepositoryError.invalidInput }
                try db.execute(sql: "INSERT INTO web_highlights(id,profile_id,url,payload,created) VALUES(?,?,?,?,?)", arguments: [record.id.uuidString, profile.uuidString, record.url, data, record.createdAt.timeIntervalSince1970])
            } else {
                try db.execute(sql: "UPDATE web_highlights SET payload=? WHERE id=? AND profile_id=?", arguments: [data, record.id.uuidString, profile.uuidString])
            }
        }
    }
    func clear(profile: UUID) throws {
        try database.queue.write { db in
            try db.execute(sql: "DELETE FROM web_highlights WHERE profile_id=?", arguments: [profile.uuidString])
        }
    }
    func remove(_ id: UUID, url: String, profile: UUID) throws {
        try database.queue.write { db in
            try db.execute(sql: "DELETE FROM web_highlights WHERE id=? AND profile_id=? AND url=?", arguments: [id.uuidString, profile.uuidString, url])
        }
    }
}

enum HighlightTool: Equatable { case off, highlight, eraser }

@MainActor @Observable final class HighlightManager {
    let store: HighlightStore
    let preferences: BrowserPreferences
    var revision = 0
    var tool: HighlightTool = .highlight
    var enabled: Bool { didSet { preferences.highlighterEnabled = enabled } }
    var style: HighlightStyle { didSet { preferences.highlightStyle = style } }
    init(database: DatabaseManager, preferences: BrowserPreferences) {
        store = HighlightStore(database: database); self.preferences = preferences
        enabled = preferences.highlighterEnabled; style = preferences.highlightStyle
    }
}
