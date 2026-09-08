import Foundation
import GRDB

enum ProfileColor: String, CaseIterable { case mint, purple, pink, orange, green, blue }

struct BrowserProfile: Identifiable, Equatable {
    static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let id: UUID
    var name: String
    let createdAt: Date
    let websiteStoreID: UUID?
    var color: ProfileColor = .mint
}

final class ProfileRepository {
    let database: DatabaseManager
    init(_ database: DatabaseManager) { self.database = database }
    func ensureDefault() throws -> BrowserProfile {
        if let profile = try list().first(where: { $0.id == BrowserProfile.defaultID }) { return profile }
        return try insert(BrowserProfile(id: BrowserProfile.defaultID, name: "Personal", createdAt: Date(), websiteStoreID: nil))
    }
    func create(name: String, color: ProfileColor = .mint) throws -> BrowserProfile {
        try insert(BrowserProfile(id: UUID(), name: validatedName(name), createdAt: Date(), websiteStoreID: UUID(), color: color))
    }
    func insert(_ profile: BrowserProfile) throws -> BrowserProfile {
        try database.queue.write { db in
            if try db.columns(in: "profiles").contains(where: { $0.name == "color" }) {
                try db.execute(sql: "INSERT INTO profiles(id,name,created_at,website_store_id,color) VALUES (?, ?, ?, ?, ?)", arguments: [profile.id.uuidString, profile.name, profile.createdAt.timeIntervalSince1970, profile.websiteStoreID?.uuidString, profile.color.rawValue])
            } else {
                try db.execute(sql: "INSERT INTO profiles(id,name,created_at,website_store_id) VALUES (?,?,?,?)", arguments: [profile.id.uuidString, profile.name, profile.createdAt.timeIntervalSince1970, profile.websiteStoreID?.uuidString])
            }
        }
        return profile
    }
    private func validatedName(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else { throw RepositoryError.invalidInput }
        return name
    }
    func update(_ id: UUID, name: String, color: ProfileColor) throws {
        let name = try validatedName(name)
        try database.queue.write { db in
            try db.execute(sql: "UPDATE profiles SET name=?,color=? WHERE id=?", arguments: [name, color.rawValue, id.uuidString])
            guard db.changesCount == 1 else { throw RepositoryError.wrongProfile }
        }
    }
    func delete(_ id: UUID) throws {
        guard id != BrowserProfile.defaultID else { throw RepositoryError.invalidInput }
        try database.queue.write { db in
            try db.execute(sql: "DELETE FROM browser_sessions WHERE profile_id=?", arguments: [id.uuidString])
            try db.execute(sql: "DELETE FROM profiles WHERE id=?", arguments: [id.uuidString])
        }
    }
    func list() throws -> [BrowserProfile] {
        try database.queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM profiles ORDER BY created_at, id").compactMap { row in
                guard let id = UUID(uuidString: row["id"]) else { return nil }
                return BrowserProfile(id: id, name: row["name"], createdAt: Date(timeIntervalSince1970: row["created_at"]),
                                      websiteStoreID: (row["website_store_id"] as String?).flatMap(UUID.init(uuidString:)),
                                      color: (row["color"] as String?).flatMap(ProfileColor.init(rawValue:)) ?? .mint)
            }
        }
    }
}
