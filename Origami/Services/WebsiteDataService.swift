import WebKit

@MainActor
final class WebsiteDataService {
    private let ephemeralStore: WKWebsiteDataStore?
    init(ephemeralStore: WKWebsiteDataStore? = nil) { self.ephemeralStore = ephemeralStore }
    func store(for profile: BrowserProfile) -> WKWebsiteDataStore {
        if let ephemeralStore { return ephemeralStore }
        if let id = profile.websiteStoreID { return WKWebsiteDataStore(forIdentifier: id) }
        return .default()
    }
    func records(profile: BrowserProfile, types: Set<String>? = nil) async -> [WKWebsiteDataRecord] {
        await store(for: profile).dataRecords(ofTypes: types ?? WKWebsiteDataStore.allWebsiteDataTypes())
    }
    func remove(_ records: [WKWebsiteDataRecord], types: Set<String>, profile: BrowserProfile) async {
        await store(for: profile).removeData(ofTypes: types.intersection(WKWebsiteDataStore.allWebsiteDataTypes()), for: records)
    }
    func clear(profile: BrowserProfile, types: Set<String>? = nil) async {
        await store(for: profile).removeData(ofTypes: types ?? WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
    // Public WebKit records expose displayName and dataTypes, not trustworthy byte counts.
    func groupedRecords(profile: BrowserProfile) async -> [String: [WKWebsiteDataRecord]] {
        Dictionary(grouping: await records(profile: profile), by: \.displayName)
    }
}
