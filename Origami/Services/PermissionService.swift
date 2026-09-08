import Foundation
import GRDB

enum SitePermission: String, CaseIterable { case camera, microphone, location, notifications, popups, autoplay, downloads, clipboard, externalProtocol }
enum PermissionDecision: String { case allow, ask, block }
final class PermissionService {
    let database: DatabaseManager
    init(_ database: DatabaseManager) { self.database = database }
    static func origin(_ url: URL) -> String? {
        guard let url = HistoryRepository.normalized(url), var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.path = ""; parts.query = nil; parts.fragment = nil
        return parts.string
    }
    func decision(_ category: SitePermission, origin: String, profileID: UUID) throws -> PermissionDecision {
        try database.queue.read { db in
            let value = try String.fetchOne(db, sql: "SELECT decision FROM permissions WHERE profile_id=? AND category=? AND origin IN (?, '*') ORDER BY origin='*' LIMIT 1", arguments: [profileID.uuidString, category.rawValue, origin])
            return value.flatMap(PermissionDecision.init(rawValue:)) ?? .ask
        }
    }
    func set(_ decision: PermissionDecision, category: SitePermission, origin: String, profileID: UUID) throws {
        guard origin == "*" || URL(string: origin).flatMap(Self.origin) == origin else { throw RepositoryError.invalidInput }
        try database.queue.write { db in
            try db.execute(sql: "INSERT INTO permissions(profile_id,origin,category,decision,updated_at) VALUES (?,?,?,?,?) ON CONFLICT(profile_id,origin,category) DO UPDATE SET decision=excluded.decision,updated_at=excluded.updated_at", arguments: [profileID.uuidString, origin, category.rawValue, decision.rawValue, Date().timeIntervalSince1970])
        }
    }
    func reset(profileID: UUID, origin: String? = nil) throws {
        try database.queue.write { db in
            if let origin { try db.execute(sql: "DELETE FROM permissions WHERE profile_id=? AND origin=?", arguments: [profileID.uuidString, origin]) }
            else { try db.execute(sql: "DELETE FROM permissions WHERE profile_id=?", arguments: [profileID.uuidString]) }
            if let origin {
                try db.execute(sql: "DELETE FROM protocol_decisions WHERE profile_id=? AND origin=?", arguments: [profileID.uuidString, origin])
                try db.execute(sql: "DELETE FROM site_rules WHERE profile_id=? AND origin=?", arguments: [profileID.uuidString, origin])
            } else {
                try db.execute(sql: "DELETE FROM protocol_decisions WHERE profile_id=?", arguments: [profileID.uuidString])
                try db.execute(sql: "DELETE FROM site_rules WHERE profile_id=?", arguments: [profileID.uuidString])
            }
        }
    }
}
