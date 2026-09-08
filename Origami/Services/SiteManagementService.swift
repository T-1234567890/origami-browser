import Foundation
import GRDB
import WebKit

struct SiteChoice {
    let origin: String
    let category: String
    let decision: String
}
extension PermissionService {
    func choices(profileID: UUID) throws -> [SiteChoice] {
        try database.queue.read { db in
            try Row.fetchAll(db, sql: "SELECT origin,category,decision FROM permissions WHERE profile_id=? ORDER BY origin,category", arguments: [profileID.uuidString]).map { SiteChoice(origin: $0["origin"], category: $0["category"], decision: $0["decision"]) }
        }
    }
    func clear(profileID: UUID, since: Date) throws {
        try database.queue.write { db in
            try db.execute(sql: "DELETE FROM permissions WHERE profile_id=? AND updated_at>=?", arguments: [profileID.uuidString, since.timeIntervalSince1970])
            try db.execute(sql: "DELETE FROM site_rules WHERE profile_id=? AND updated_at>=?", arguments: [profileID.uuidString, since.timeIntervalSince1970])
            try db.execute(sql: "DELETE FROM protocol_decisions WHERE profile_id=? AND updated_at>=?", arguments: [profileID.uuidString, since.timeIntervalSince1970])
        }
    }
    func siteRule(_ rule: String, origin: String, profileID: UUID) throws -> Bool {
        guard ["never_sleep", "muted"].contains(rule) else { throw RepositoryError.invalidInput }
        return try database.queue.read { try Bool.fetchOne($0, sql: "SELECT \(rule) FROM site_rules WHERE profile_id=? AND origin=?", arguments: [profileID.uuidString, origin]) ?? false }
    }
    func setSiteRule(_ rule: String, value: Bool, origin: String, profileID: UUID) throws {
        guard ["never_sleep", "muted"].contains(rule), URL(string: origin).flatMap(Self.origin) == origin else { throw RepositoryError.invalidInput }
        try database.queue.write { try $0.execute(sql: "INSERT INTO site_rules(profile_id,origin,\(rule),updated_at) VALUES (?,?,?,?) ON CONFLICT(profile_id,origin) DO UPDATE SET \(rule)=excluded.\(rule),updated_at=excluded.updated_at", arguments: [profileID.uuidString, origin, value, Date().timeIntervalSince1970]) }
    }
}
@MainActor
final class ClearBrowsingDataService {
    static let dataTypes: [String: String] = ["cookies": WKWebsiteDataTypeCookies, "cache": WKWebsiteDataTypeDiskCache,
        "localStorage": WKWebsiteDataTypeLocalStorage, "indexedDB": WKWebsiteDataTypeIndexedDBDatabases, "serviceWorkers": WKWebsiteDataTypeServiceWorkerRegistrations]
    let services: BrowserServices
    init(_ services: BrowserServices) { self.services = services }
    func clear(profile: BrowserProfile, categories: Set<String>, since: Date) async throws {
        if categories.contains("history") { try services.history.clear(profileID: profile.id, since: since); try services.ai.clearHistory(profile: profile.id, since: since) }
        if categories.contains("downloads") { try services.downloadRepository.clear(profileID: profile.id, since: since) }
        if categories.contains("permissions") { try services.permissions.clear(profileID: profile.id, since: since) }
        var types = Set(categories.compactMap { Self.dataTypes[$0] })
        if categories.contains("cache") { types.insert(WKWebsiteDataTypeMemoryCache) }
        if !types.isEmpty { await services.websiteData.store(for: profile).removeData(ofTypes: types, modifiedSince: since) }
    }
}
extension DownloadRepository {
    func remove(_ id: UUID, profileID: UUID) throws {
        try database.queue.write { try $0.execute(sql: "DELETE FROM downloads WHERE id=? AND profile_id=? AND state NOT IN ('running','choosingDestination')", arguments: [id.uuidString, profileID.uuidString]) }
    }
    func clear(profileID: UUID, since: Date = .distantPast, completedOnly: Bool = false) throws {
        try database.queue.write { try $0.execute(sql: "DELETE FROM downloads WHERE profile_id=? AND created_at>=? AND state NOT IN ('running','choosingDestination') AND (?=0 OR state='completed')", arguments: [profileID.uuidString, since.timeIntervalSince1970, completedOnly]) }
    }
}

extension PermissionService {
    func rules(profileID: UUID) throws -> [[String: Any]] {
        try database.queue.read { db in
            try Row.fetchAll(db, sql: "SELECT origin,muted,never_sleep FROM site_rules WHERE profile_id=? ORDER BY origin", arguments: [profileID.uuidString]).map {
                ["origin": $0["origin"] as String, "muted": $0["muted"] as Bool, "never_sleep": $0["never_sleep"] as Bool]
            }
        }
    }
}
