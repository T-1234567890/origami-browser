import Foundation
import GRDB

extension ExternalProtocolService {
    func list(profileID: UUID) throws -> [[String: String]] {
        try permissions.database.queue.read { db in
            try Row.fetchAll(db, sql: "SELECT origin,scheme,decision FROM protocol_decisions WHERE profile_id=? ORDER BY origin,scheme", arguments: [profileID.uuidString]).map { ["origin": $0["origin"], "scheme": $0["scheme"], "decision": $0["decision"]] }
        }
    }
    func set(_ decision: PermissionDecision, origin: String, scheme: String, profileID: UUID) throws {
        guard URL(string: origin).flatMap(PermissionService.origin) == origin, !scheme.isEmpty, scheme.count < 80,
              scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }) else { throw RepositoryError.invalidInput }
        try permissions.database.queue.write { db in
            if decision == .ask { try db.execute(sql: "DELETE FROM protocol_decisions WHERE profile_id=? AND origin=? AND scheme=?", arguments: [profileID.uuidString, origin, scheme.lowercased()]) }
            else { try db.execute(sql: "INSERT INTO protocol_decisions VALUES(?,?,?,?,?) ON CONFLICT(profile_id,origin,scheme) DO UPDATE SET decision=excluded.decision,updated_at=excluded.updated_at", arguments: [profileID.uuidString, origin, scheme.lowercased(), decision.rawValue, Date().timeIntervalSince1970]) }
        }
    }
}
