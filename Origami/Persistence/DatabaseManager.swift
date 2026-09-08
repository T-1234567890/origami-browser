import Foundation
import GRDB

final class DatabaseManager {
    let queue: DatabaseQueue
    init(fileURL: URL? = nil, migrate: Bool = true) throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.busyMode = .timeout(5)
        if let fileURL {
            try DatabaseStorageProtection.prepare(fileURL)
            queue = try DatabaseQueue(path: fileURL.path, configuration: configuration)
            try queue.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;")
            }
            try DatabaseStorageProtection.sidecars(fileURL)
        } else { queue = try DatabaseQueue(configuration: configuration) }
        if migrate {
            try queue.read { db in
                if try db.tableExists("grdb_migrations") {
                    let applied = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
                    guard Set(applied).isSubset(of: Set(Migrations.names)) else { throw CocoaError(.fileReadUnknown) }
                }
            }
            try Migrations.make().migrate(queue)
            if let fileURL { try DatabaseStorageProtection.sidecars(fileURL) }
        }
    }
}
