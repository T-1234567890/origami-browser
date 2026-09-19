import Foundation
import GRDB

enum ProfileDataKind: String, CaseIterable, Identifiable {
    case website, history, bookmarks, appearance, layout
    var id: Self { self }
    var title: String {
        switch self {
        case .website: "Website data and sign-ins"
        case .history: "History"
        case .bookmarks: "Bookmarks"
        case .appearance: "Appearance"
        case .layout: "Tab layout"
        }
    }
}

/// Personal is the stable, undeletable sharing destination. A profile's own
/// storage remains untouched when it opts into or out of sharing.
struct ProfileSharing: Codable, Equatable {
    var website = false
    var history = false
    var bookmarks = false
    var appearance = true
    var layout = true
    subscript(_ kind: ProfileDataKind) -> Bool {
        get {
            switch kind {
            case .website: website
            case .history: history
            case .bookmarks: bookmarks
            case .appearance: appearance
            case .layout: layout
            }
        }
        set {
            switch kind {
            case .website: website = newValue
            case .history: history = newValue
            case .bookmarks: bookmarks = newValue
            case .appearance: appearance = newValue
            case .layout: layout = newValue
            }
        }
    }
}

extension ProfileRepository {
    static func scope(_ id: UUID, _ kind: ProfileDataKind, in db: Database) throws -> UUID {
        guard id != BrowserProfile.defaultID else { return id }
        guard let row = try Row.fetchOne(db, sql: "SELECT sharing FROM profiles WHERE id=?", arguments: [id.uuidString]) else { return id }
        let sharing = try (row["sharing"] as Data?).map { try JSONDecoder().decode(ProfileSharing.self, from: $0) } ?? ProfileSharing()
        return sharing[kind] ? BrowserProfile.defaultID : id
    }
    func scope(_ id: UUID, _ kind: ProfileDataKind) throws -> UUID {
        try database.queue.read { try Self.scope(id, kind, in: $0) }
    }
    func setSharing(_ sharing: ProfileSharing, for id: UUID) throws {
        guard id != BrowserProfile.defaultID else { return }
        let data = try JSONEncoder().encode(sharing)
        try database.queue.write { db in
            try db.execute(sql: "UPDATE profiles SET sharing=? WHERE id=?", arguments: [data, id.uuidString])
            guard db.changesCount == 1 else { throw RepositoryError.wrongProfile }
        }
    }
}
