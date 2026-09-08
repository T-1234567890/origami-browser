import AppKit
import GRDB

@MainActor
final class ExternalProtocolService {
    let permissions: PermissionService
    init(permissions: PermissionService) { self.permissions = permissions }
    func decision(for url: URL, source: URL?, profileID: UUID) throws -> PermissionDecision {
        guard let scheme = url.scheme?.lowercased(), !["http", "https", "origami", "file", "javascript", "data", "blob", "about"].contains(scheme) else { return .block }
        guard let source, let origin = PermissionService.origin(source) else { return .ask }
        let stored = try permissions.database.queue.read { try String.fetchOne($0, sql: "SELECT decision FROM protocol_decisions WHERE profile_id=? AND origin=? AND scheme=?", arguments: [profileID.uuidString, origin, scheme]) }
        if let decision = stored.flatMap(PermissionDecision.init(rawValue:)) { return decision }
        return try permissions.decision(.externalProtocol, origin: origin, profileID: profileID)
    }
    private var lastOpened = Date.distantPast
    func openOnce(_ url: URL) { guard Date().timeIntervalSince(lastOpened) > 2 else { return }; lastOpened = Date(); NSWorkspace.shared.open(url) }
}
