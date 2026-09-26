import Foundation
import GRDB

enum ProfileColor: String, CaseIterable { case mint, purple, pink, orange, green, blue }

struct BrowserProfile: Identifiable, Equatable {
    // Legacy Personal identity and preference-storage key; use profiles.defaultID for the selected default.
    static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let id: UUID
    var name: String
    let createdAt: Date
    let websiteStoreID: UUID?
    var color: ProfileColor = .mint
    var sharing = ProfileSharing()
}

final class ProfileRepository {
    let database: DatabaseManager
    init(_ database: DatabaseManager) { self.database = database }
    var defaultID: UUID { (try? database.queue.read { try Self.defaultID(in: $0) }) ?? BrowserProfile.defaultID }
    static func defaultID(in db: Database) throws -> UUID {
        guard try db.columns(in: "profiles").contains(where: { $0.name == "is_default" }) else { return BrowserProfile.defaultID }
        return try String.fetchOne(db, sql: "SELECT id FROM profiles WHERE is_default=1").flatMap(UUID.init(uuidString:)) ?? BrowserProfile.defaultID
    }
    func setDefault(_ id: UUID) throws {
        try database.queue.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM profiles WHERE id=?)", arguments: [id.uuidString]) == true else { throw RepositoryError.wrongProfile }
            let old = try Self.defaultID(in: db)
            // The former default keeps its own data instead of inheriting the new default.
            var own = ProfileSharing()
            for kind in ProfileDataKind.allCases { own[kind] = false }
            try db.execute(sql: "UPDATE profiles SET sharing=? WHERE id=? OR id=?", arguments: [try JSONEncoder().encode(own), old.uuidString, id.uuidString])
            try db.execute(sql: "UPDATE profiles SET is_default=0 WHERE is_default=1")
            try db.execute(sql: "UPDATE profiles SET is_default=1 WHERE id=?", arguments: [id.uuidString])
        }
    }
    func ensureDefault() throws -> BrowserProfile {
        if let profile = try list().first(where: { $0.id == defaultID }) { return profile }
        return try insert(BrowserProfile(id: BrowserProfile.defaultID, name: "Personal", createdAt: Date(), websiteStoreID: nil))
    }
    func create(name: String, color: ProfileColor = .mint, sharing: ProfileSharing = ProfileSharing()) throws -> BrowserProfile {
        try insert(BrowserProfile(id: UUID(), name: validatedName(name), createdAt: Date(), websiteStoreID: UUID(), color: color, sharing: sharing))
    }
    func insert(_ profile: BrowserProfile) throws -> BrowserProfile {
        try database.queue.write { db in
            if try db.columns(in: "profiles").contains(where: { $0.name == "color" }) {
                try db.execute(sql: "INSERT INTO profiles(id,name,created_at,website_store_id,color) VALUES (?, ?, ?, ?, ?)", arguments: [profile.id.uuidString, profile.name, profile.createdAt.timeIntervalSince1970, profile.websiteStoreID?.uuidString, profile.color.rawValue])
            } else {
                try db.execute(sql: "INSERT INTO profiles(id,name,created_at,website_store_id) VALUES (?,?,?,?)", arguments: [profile.id.uuidString, profile.name, profile.createdAt.timeIntervalSince1970, profile.websiteStoreID?.uuidString])
            }
            if try db.columns(in: "profiles").contains(where: { $0.name == "sharing" }) {
                try db.execute(sql: "UPDATE profiles SET sharing=? WHERE id=?", arguments: [try JSONEncoder().encode(profile.sharing), profile.id.uuidString])
            }
        }
        return profile
    }
    private func validatedName(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else { throw RepositoryError.invalidInput }
        return name
    }
    func update(_ id: UUID, name: String, color: ProfileColor, sharing: ProfileSharing? = nil) throws {
        let name = try validatedName(name)
        try database.queue.write { db in
            try db.execute(sql: "UPDATE profiles SET name=?,color=?,sharing=COALESCE(?,sharing) WHERE id=?", arguments: [name, color.rawValue, try sharing.map { try JSONEncoder().encode($0) }, id.uuidString])
            guard db.changesCount == 1 else { throw RepositoryError.wrongProfile }
        }
    }
    func delete(_ id: UUID) throws {
        try database.queue.write { db in
            guard id != (try Self.defaultID(in: db)) else { throw RepositoryError.invalidInput }
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
                                      color: (row["color"] as String?).flatMap(ProfileColor.init(rawValue:)) ?? .mint,
                                      sharing: (row.hasColumn("sharing") ? row["sharing"] as Data? : nil).flatMap { try? JSONDecoder().decode(ProfileSharing.self, from: $0) } ?? ProfileSharing())
            }
        }
    }
}
