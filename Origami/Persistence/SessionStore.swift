import Foundation

/// Persistence boundary retained for BrowserStore; JSON is accepted only as a one-time legacy import.
final class SessionStore {
    let fileURL: URL
    let preferences: BrowserPreferences
    private let legacyURL: URL?
    private lazy var initialization: Result<DatabaseManager, Error> = Result {
        let database = try DatabaseManager(fileURL: fileURL)
        _ = try ProfileRepository(database).ensureDefault()
        return database
    }
    var database: DatabaseManager { get throws { try initialization.get() } }
    init(fileURL: URL? = nil, preferences: BrowserPreferences? = nil, legacyURL: URL? = nil) {
        let directory = URL.applicationSupportDirectory.appending(path: "Origami")
        self.fileURL = fileURL ?? directory.appending(path: "browser.sqlite")
        self.preferences = preferences ?? BrowserPreferences(defaults: fileURL == nil ? .standard : nil)
        self.legacyURL = legacyURL ?? (fileURL == nil ? directory.appending(path: "session.json") : nil)
    }
    func load() throws -> BrowserSession {
        let repository = SessionRepository(try database)
        let profiles = try ProfileRepository(database).list()
        let profileID = profiles.contains(where: { $0.id == preferences.currentProfileID }) ? preferences.currentProfileID : BrowserProfile.defaultID
        var session = try repository.load(profileID: profileID)
        if session == nil, let legacyURL, FileManager.default.fileExists(atPath: legacyURL.path) {
            var imported = try JSONDecoder().decode(BrowserSession.self, from: Data(contentsOf: legacyURL))
            guard imported.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
            imported.normalize()
            try repository.save(imported)
            preferences.save(imported)
            session = imported
        }
        var result = session ?? BrowserSession()
        result.profileID = profileID
        preferences.apply(to: &result)
        if !result.restoreSession { result.tabs = result.tabs.filter(\.isPinned) + [BrowserTab()]; result.groups = []; result.selectedTabID = result.tabs.last?.id }
        result.normalize()
        return result
    }
    func save(_ session: BrowserSession, recentlyClosed: [(tab: BrowserTab, index: Int)] = [], savePreferences: Bool = true) throws {
        try SessionRepository(database).save(session, recentlyClosed: recentlyClosed)
        if savePreferences { preferences.save(session) }
    }
}
