import Foundation
import GRDB

extension BookmarkRepository {
    func importItems(_ items: [ImportedBookmark], profileID: UUID) throws -> Int {
        try database.queue.write { db in
            var count = 0
            func insert(_ items: [ImportedBookmark], parent: UUID?) throws {
                var position = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(position),-1)+1 FROM bookmarks WHERE profile_id=? AND folder_id IS ?", arguments: [profileID.uuidString, parent?.uuidString]) ?? 0
                for item in items {
                    switch item {
                    case let .folder(title, children):
                        let id = UUID()
                        try db.execute(sql: "INSERT INTO bookmark_folders VALUES(?,?,?,?,?)", arguments: [id.uuidString, profileID.uuidString, parent?.uuidString, title, position])
                        try insert(children, parent: id)
                    case let .bookmark(title, url):
                        let existing = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bookmarks WHERE profile_id=? AND folder_id IS ? AND url=?", arguments: [profileID.uuidString, parent?.uuidString, url.absoluteString]) ?? 0
                        if existing == 0 {
                            try db.execute(sql: "INSERT INTO bookmarks(id,profile_id,folder_id,title,url,position,created_at) VALUES(?,?,?,?,?,?,?)", arguments: [UUID().uuidString, profileID.uuidString, parent?.uuidString, title, url.absoluteString, position, Date().timeIntervalSince1970])
                            count += 1
                        }
                    }
                    position += 1
                }
            }
            try insert(items, parent: nil)
            return count
        }
    }
    func library(profileID: UUID, folderID: UUID?, search: String = "", offset: Int = 0, favorites: Bool = false) throws -> [[String: Any]] {
        try database.queue.read { db in
            try Row.fetchAll(db, sql: """
            SELECT * FROM bookmarks WHERE profile_id=? AND (?=1 OR ?<>'' OR folder_id IS ?)
              AND (?='' OR title LIKE ? ESCAPE '\\' OR url LIKE ? ESCAPE '\\') AND (?=0 OR favorite=1)
            ORDER BY position,id LIMIT 100 OFFSET ?
            """, arguments: [profileID.uuidString, favorites, search, folderID?.uuidString, search,
                             "%" + HistoryRepository.escapeLike(search) + "%", "%" + HistoryRepository.escapeLike(search) + "%", favorites, max(0, offset)]).map {
                ["id": $0["id"] as String, "title": $0["title"] as String, "url": $0["url"] as String,
                 "folderID": ($0["folder_id"] as String?) ?? "", "favorite": $0["favorite"] as Bool, "position": $0["position"] as Int]
            }
        }
    }
    func edit(_ id: UUID, url: URL, title: String, folderID: UUID?, favorite: Bool, profileID: UUID) throws {
        guard let clean = PersistedURL.clean(url) else { throw RepositoryError.invalidInput }
        try database.queue.write { db in
            if let folderID, try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bookmark_folders WHERE id=? AND profile_id=?", arguments: [folderID.uuidString, profileID.uuidString]) != 1 { throw RepositoryError.wrongProfile }
            try db.execute(sql: "UPDATE bookmarks SET url=?,title=?,folder_id=?,favorite=? WHERE id=? AND profile_id=?", arguments: [clean.absoluteString, title, folderID?.uuidString, favorite, id.uuidString, profileID.uuidString])
        }
    }
    func moveFolder(_ id: UUID, parentID: UUID?, position: Int, profileID: UUID) throws {
        try database.queue.write { db in
            if let parentID {
                guard parentID != id, try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bookmark_folders WHERE id=? AND profile_id=?", arguments: [parentID.uuidString, profileID.uuidString]) == 1 else { throw RepositoryError.invalidInput }
                let cycle = try Int.fetchOne(db, sql: "WITH RECURSIVE descendants(id) AS (SELECT id FROM bookmark_folders WHERE id=? UNION SELECT f.id FROM bookmark_folders f JOIN descendants d ON f.parent_id=d.id) SELECT COUNT(*) FROM descendants WHERE id=?", arguments: [id.uuidString, parentID.uuidString])!
                guard cycle == 0 else { throw RepositoryError.invalidInput }
            }
            try db.execute(sql: "UPDATE bookmark_folders SET parent_id=?,position=? WHERE id=? AND profile_id=?", arguments: [parentID?.uuidString, position, id.uuidString, profileID.uuidString])
        }
    }
    func reorder(_ id: UUID, before target: UUID, profileID: UUID) throws {
        try database.queue.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT folder_id,position FROM bookmarks WHERE id=? AND profile_id=?", arguments: [target.uuidString, profileID.uuidString]) else { throw RepositoryError.invalidInput }
            let folder: String? = row["folder_id"]
            let position: Int = row["position"]
            try db.execute(sql: "UPDATE bookmarks SET position=position+1 WHERE profile_id=? AND folder_id IS ? AND position>=?", arguments: [profileID.uuidString, folder, position])
            try db.execute(sql: "UPDATE bookmarks SET folder_id=?,position=? WHERE id=? AND profile_id=?", arguments: [folder, position, id.uuidString, profileID.uuidString])
        }
    }
    @discardableResult func addUnique(url: URL, title: String, folderID: UUID? = nil, profileID: UUID) throws -> UUID {
        guard let clean = PersistedURL.clean(url) else { throw RepositoryError.invalidInput }
        if let existing = try database.queue.read({ try String.fetchOne($0, sql: "SELECT id FROM bookmarks WHERE profile_id=? AND folder_id IS ? AND url=?", arguments: [profileID.uuidString, folderID?.uuidString, clean.absoluteString]) }), let id = UUID(uuidString: existing) { return id }
        let position = try database.queue.read { try Int.fetchOne($0, sql: "SELECT COALESCE(MAX(position),-1)+1 FROM bookmarks WHERE profile_id=? AND folder_id IS ?", arguments: [profileID.uuidString, folderID?.uuidString])! }
        return try create(url: clean, title: title, folderID: folderID, position: position, profileID: profileID)
    }
    func folderBookmarks(_ folder: UUID, profileID: UUID) throws -> [Bookmark] {
        let ids: Set<String> = try database.queue.read { db in
            Set(try String.fetchAll(db, sql: "WITH RECURSIVE f(id) AS (SELECT id FROM bookmark_folders WHERE id=? AND profile_id=? UNION SELECT b.id FROM bookmark_folders b JOIN f ON b.parent_id=f.id) SELECT id FROM f", arguments: [folder.uuidString, profileID.uuidString]))
        }
        return try list(profileID: profileID).filter { $0.folderID.map { ids.contains($0.uuidString) } ?? false }
    }
}
