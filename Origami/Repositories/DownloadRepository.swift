import Foundation
import GRDB

enum DownloadState: String { case choosingDestination, running, cancelled, failed, completed, interrupted }
struct DownloadRecord: Identifiable {
    var id = UUID()
    let profileID: UUID
    let tabID: UUID?
    var url: String
    var filename = ""
    var destination: String?
    var bookmark: Data?
    var state: DownloadState = .choosingDestination
    var received: Int64 = 0
    var expected: Int64?
    var error: String?
    var createdAt = Date()
}
final class DownloadRepository {
    let database: DatabaseManager
    init(_ database: DatabaseManager) { self.database = database }
    static func safeHistoryURL(_ value: String) -> String {
        DownloadQuarantine.metadataURL(URL(string: value))?.absoluteString ?? ""
    }
    func save(_ record: DownloadRecord) throws {
        try database.queue.write { db in
            try db.execute(sql: """
            INSERT INTO downloads VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
            url=excluded.url,filename=excluded.filename,destination=excluded.destination,bookmark=excluded.bookmark,state=excluded.state,
            received=excluded.received,expected=excluded.expected,error=excluded.error,updated_at=excluded.updated_at
            """, arguments: [record.id.uuidString, record.profileID.uuidString, record.tabID?.uuidString, Self.safeHistoryURL(record.url), record.filename, record.destination, record.bookmark, record.state.rawValue, record.received, record.expected, record.error, record.createdAt.timeIntervalSince1970, Date().timeIntervalSince1970])
        }
    }
    func list(profileID: UUID, limit: Int = 100, offset: Int = 0, id: UUID? = nil) throws -> [DownloadRecord] {
        try database.queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM downloads WHERE profile_id=? AND (? IS NULL OR id=?) ORDER BY created_at DESC,id LIMIT ? OFFSET ?", arguments: [profileID.uuidString, id?.uuidString, id?.uuidString, min(max(limit, 1), 100), max(offset, 0)]).compactMap { row in
                guard let id = UUID(uuidString: row["id"]) else { return nil }
                return DownloadRecord(id: id, profileID: profileID, tabID: (row["tab_id"] as String?).flatMap(UUID.init(uuidString:)), url: row["url"], filename: row["filename"], destination: row["destination"], bookmark: row["bookmark"], state: DownloadState(rawValue: row["state"]) ?? .failed, received: row["received"], expected: row["expected"], error: row["error"], createdAt: Date(timeIntervalSince1970: row["created_at"]))
            }
        }
    }
    func recoverInterrupted() throws {
        try database.queue.write { db in
            // Remove sensitive URL components from existing metadata as well.
            for row in try Row.fetchAll(db, sql: "SELECT id,url FROM downloads") {
                let url: String = row["url"]
                let safe = Self.safeHistoryURL(url)
                if safe != url { try db.execute(sql: "UPDATE downloads SET url=? WHERE id=?", arguments: [safe, row["id"] as String]) }
            }
            try db.execute(sql: "UPDATE downloads SET state='interrupted' WHERE state IN ('running','choosingDestination')")
        }
    }
}
