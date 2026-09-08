import Foundation
import GRDB

struct Bookmark: Identifiable {
    let id: UUID
    let folderID: UUID?
    let title: String
    let url: String
    let position: Int
}
struct BookmarkFolder: Identifiable {
    let id: UUID
    let parentID: UUID?
    let title: String
    let position: Int
}
enum RepositoryError: Error { case invalidInput, wrongProfile }
final class BookmarkRepository {
    let database: DatabaseManager
    init(_ database: DatabaseManager) { self.database = database }
    private func validateFolder(_ id: UUID?, profileID: UUID, db: Database) throws {
        if let id, try !Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM bookmark_folders WHERE id=? AND profile_id=?)", arguments: [id.uuidString, profileID.uuidString])! { throw RepositoryError.wrongProfile }
    }
    @discardableResult func createFolder(title: String, parentID: UUID? = nil, position: Int = 0, profileID: UUID) throws -> UUID {
        let id = UUID()
        try database.queue.write { db in
            try validateFolder(parentID, profileID: profileID, db: db)
            try db.execute(sql: "INSERT INTO bookmark_folders VALUES (?,?,?,?,?)", arguments: [id.uuidString, profileID.uuidString, parentID?.uuidString, title, position])
        }
        return id
    }
    @discardableResult func create(url: URL, title: String, folderID: UUID? = nil, position: Int = 0, profileID: UUID) throws -> UUID {
        guard let url = PersistedURL.clean(url) else { throw RepositoryError.invalidInput }
        let id = UUID()
        try database.queue.write { db in
            try validateFolder(folderID, profileID: profileID, db: db)
            try db.execute(sql: "INSERT INTO bookmarks(id,profile_id,folder_id,title,url,position,created_at) VALUES (?,?,?,?,?,?,?)", arguments: [id.uuidString, profileID.uuidString, folderID?.uuidString, title, url.absoluteString, position, Date().timeIntervalSince1970])
        }
        return id
    }
    func bookmark(url: URL, profileID: UUID) throws -> Bookmark? {
        guard let url = PersistedURL.clean(url) else { return nil }
        return try database.queue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM bookmarks WHERE profile_id=? AND url=? ORDER BY position,id LIMIT 1", arguments: [profileID.uuidString, url.absoluteString]),
                  let id = UUID(uuidString: row["id"]) else { return nil }
            return Bookmark(id: id, folderID: (row["folder_id"] as String?).flatMap(UUID.init(uuidString:)), title: row["title"], url: row["url"], position: row["position"])
        }
    }
    func editDetails(_ id: UUID, url: URL, title: String, folderID: UUID?, profileID: UUID) throws {
        guard let url = PersistedURL.clean(url), ["https", "http"].contains(url.scheme), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RepositoryError.invalidInput }
        try database.queue.write { db in
            try validateFolder(folderID, profileID: profileID, db: db)
            try db.execute(sql: "UPDATE bookmarks SET title=?,url=?,folder_id=? WHERE id=? AND profile_id=?", arguments: [title, url.absoluteString, folderID?.uuidString, id.uuidString, profileID.uuidString])
            guard db.changesCount == 1 else { throw RepositoryError.invalidInput }
        }
    }
    func removePage(url: URL, profileID: UUID) throws {
        guard let url = PersistedURL.clean(url) else { throw RepositoryError.invalidInput }
        try database.queue.write { try $0.execute(sql: "DELETE FROM bookmarks WHERE profile_id=? AND url=?", arguments: [profileID.uuidString, url.absoluteString]) }
    }
    func contains(url: URL, profileID: UUID) throws -> Bool {
        guard let url = PersistedURL.clean(url) else { return false }
        return try database.queue.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM bookmarks WHERE profile_id=? AND url=?)", arguments: [profileID.uuidString, url.absoluteString]) ?? false
        }
    }
    func suggestionCandidates(query: String, profileID: UUID) throws -> [(Bookmark, String)] {
        let words = query.split(whereSeparator: \.isWhitespace).prefix(12)
        guard !words.isEmpty else { return [] }
        func escaped(_ text: String) -> String { text.replacingOccurrences(of: "!", with: "!!").replacingOccurrences(of: "%", with: "!%").replacingOccurrences(of: "_", with: "!_") }
        let clauses = words.map { _ in "(b.title LIKE ? ESCAPE '!' OR b.url LIKE ? ESCAPE '!' OR f.title LIKE ? ESCAPE '!')" }.joined(separator: " AND ")
        var arguments: [DatabaseValueConvertible] = [profileID.uuidString]
        for word in words { let pattern = "%" + escaped(String(word)) + "%"; arguments += [pattern, pattern, pattern] }
        let prefix = escaped(query) + "%"
        arguments += [prefix, prefix, "https://" + prefix, "http://" + prefix]
        return try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT b.*, COALESCE(f.title, '') AS folder_title FROM bookmarks b
                LEFT JOIN bookmark_folders f ON f.id=b.folder_id AND f.profile_id=b.profile_id
                WHERE b.profile_id=? AND \(clauses)
                ORDER BY (b.title LIKE ? ESCAPE '!' OR b.url LIKE ? ESCAPE '!' OR b.url LIKE ? ESCAPE '!' OR b.url LIKE ? ESCAPE '!') DESC, b.position, b.id LIMIT 100
                """, arguments: StatementArguments(arguments)).compactMap { row in
                    guard let id = UUID(uuidString: row["id"]) else { return nil }
                    return (Bookmark(id: id, folderID: (row["folder_id"] as String?).flatMap(UUID.init(uuidString:)), title: row["title"], url: row["url"], position: row["position"]), row["folder_title"])
                }
        }
    }
    func list(profileID: UUID) throws -> [Bookmark] {
        try database.queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM bookmarks WHERE profile_id=? ORDER BY position,id", arguments: [profileID.uuidString]).compactMap {
                guard let id = UUID(uuidString: $0["id"]) else { return nil }
                return Bookmark(id: id, folderID: ($0["folder_id"] as String?).flatMap(UUID.init(uuidString:)), title: $0["title"], url: $0["url"], position: $0["position"])
            }
        }
    }
    func folders(profileID: UUID) throws -> [BookmarkFolder] {
        try database.queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM bookmark_folders WHERE profile_id=? ORDER BY position,id", arguments: [profileID.uuidString]).compactMap {
                guard let id = UUID(uuidString: $0["id"]) else { return nil }
                return BookmarkFolder(id: id, parentID: ($0["parent_id"] as String?).flatMap(UUID.init(uuidString:)), title: $0["title"], position: $0["position"])
            }
        }
    }
    func update(_ id: UUID, title: String, folderID: UUID?, position: Int, profileID: UUID) throws {
        try database.queue.write { db in
            try validateFolder(folderID, profileID: profileID, db: db)
            try db.execute(sql: "UPDATE bookmarks SET title=?,folder_id=?,position=? WHERE id=? AND profile_id=?", arguments: [title, folderID?.uuidString, position, id.uuidString, profileID.uuidString])
        }
    }
    func renameFolder(_ id: UUID, title: String, profileID: UUID) throws {
        try database.queue.write { try $0.execute(sql: "UPDATE bookmark_folders SET title=? WHERE id=? AND profile_id=?", arguments: [title, id.uuidString, profileID.uuidString]) }
    }
    func delete(_ id: UUID, profileID: UUID) throws {
        try database.queue.write { try $0.execute(sql: "DELETE FROM bookmarks WHERE id=? AND profile_id=?", arguments: [id.uuidString, profileID.uuidString]) }
    }
    func deleteFolder(_ id: UUID, profileID: UUID) throws {
        try database.queue.write { try $0.execute(sql: "DELETE FROM bookmark_folders WHERE id=? AND profile_id=?", arguments: [id.uuidString, profileID.uuidString]) }
    }
}
