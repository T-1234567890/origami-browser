import WebKit

@MainActor
final class BrowserServices {
    private var retentionTimer: Timer?
    private let retentionPreferences: BrowserPreferences
    private let retention: HistoryRetention
    let ai: AIController
    let power: PowerRepository
    let feeds: FeedService
    let profiles: ProfileRepository
    let history: HistoryRepository
    let bookmarks: BookmarkRepository
    let downloadRepository: DownloadRepository
    let downloads: DownloadService
    let permissions: PermissionService
    let externalProtocols: ExternalProtocolService
    let websiteData: WebsiteDataService
    let isPrivate: Bool
    let media = MediaStateService()
    let favicons = FaviconService()
    let lifecycle = TabLifecycleService()
    init(database: DatabaseManager, preferences: BrowserPreferences? = nil, privateProfile: BrowserProfile? = nil,
         sharedBookmarks: BookmarkRepository? = nil) throws {
        retentionPreferences = preferences ?? BrowserPreferences()
        retention = HistoryRetention(database: database)
        ai = AIController(database: database, isPrivate: privateProfile != nil)
        power = PowerRepository(database)
        feeds = FeedService(database: database)
        isPrivate = privateProfile != nil
        websiteData = WebsiteDataService(ephemeralStore: privateProfile == nil ? nil : .nonPersistent())
        profiles = ProfileRepository(database)
        _ = try profiles.ensureDefault()
        if let privateProfile, privateProfile.id != BrowserProfile.defaultID { _ = try profiles.insert(privateProfile) }
        history = HistoryRepository(database)
        bookmarks = sharedBookmarks ?? BookmarkRepository(database)
        downloadRepository = DownloadRepository(database)
        try downloadRepository.recoverInterrupted()
        downloads = DownloadService(repository: downloadRepository, preferences: preferences)
        permissions = PermissionService(database)
        externalProtocols = ExternalProtocolService(permissions: permissions)
        if !isPrivate {
            try runHistoryCleanup()
            retentionTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { try? self?.runHistoryCleanup() }
            }
        }
    }
    deinit { retentionTimer?.invalidate() }
    func runHistoryCleanup() throws {
        guard !isPrivate else { return }
        let active = Set(ai.events.values.filter { $0.status == "Requesting answer" || $0.explorations?.contains(where: { $0.status == "Requesting answer" }) == true }.map(\.id))
        let removed = try retention.clean(days: retentionPreferences.historyRetentionDays, keeping: active)
        ai.discardExpiredHistory(removed)
        NotificationCenter.default.post(name: .origamiHistoryChanged, object: nil)
    }
    func websiteStore(profileID: UUID) throws -> WKWebsiteDataStore {
        guard let profile = try profiles.list().first(where: { $0.id == profileID }) else { throw RepositoryError.wrongProfile }
        return websiteData.store(for: profile)
    }
}
