import Foundation

final class BrowserPreferences {
    private let defaults: UserDefaults?
    private var values: [String: Any] = [:]
    init(defaults: UserDefaults? = nil) { self.defaults = defaults }
    private func value(_ key: String) -> Any? { defaults?.object(forKey: "browser." + key) ?? values[key] }
    private func set(_ value: Any, _ key: String) {
        if let defaults { defaults.set(value, forKey: "browser." + key) } else { values[key] = value }
    }
    var hasPersistentStorage: Bool { defaults != nil }
    var httpsFirst: Bool {
        get { value("httpsFirst") as? Bool ?? true }
        set { set(newValue, "httpsFirst") }
    }
    var contentBlockingDomains: [String] {
        get { value("contentBlockingDomains") as? [String] ?? [] }
        set { set(newValue, "contentBlockingDomains") }
    }
    var contentBlocking: Bool {
        get { value("contentBlocking") as? Bool ?? false }
        set { set(newValue, "contentBlocking") }
    }
    var adBlocking: Bool {
        get { value("adBlocking") as? Bool ?? false }
        set { set(newValue, "adBlocking") }
    }
    func blockingExceptions(_ kind: BlockingKind) -> [String] { value("blockingExceptions." + kind.rawValue) as? [String] ?? [] }
    func setBlockingExceptions(_ hosts: [String], kind: BlockingKind) { set(hosts, "blockingExceptions." + kind.rawValue) }
    var highlighterEnabled: Bool {
        get { value("highlighterEnabled") as? Bool ?? false }
        set { set(newValue, "highlighterEnabled") }
    }
    var highlightStyle: HighlightStyle {
        get { (value("highlightStyle") as? String).flatMap(HighlightStyle.init(rawValue:)) ?? .yellow }
        set { set(newValue.rawValue, "highlightStyle") }
    }
    var peekMode: PeekMode {
        get { (value("peekMode") as? String).flatMap(PeekMode.init(rawValue:)) ?? .onDemand }
        set { set(newValue.rawValue, "peekMode") }
    }
    var historyRetentionDays: Int {
        get { let days = value("historyRetentionDays") as? Int ?? 90; return [30, 90, 180, 365, 0].contains(days) ? days : 90 }
        set { if [30, 90, 180, 365, 0].contains(newValue) { set(newValue, "historyRetentionDays") } }
    }
    var safariInspectionInstructionsSeen: Bool {
        get { value("safariInspectionInstructionsSeen") as? Bool ?? false }
        set { set(newValue, "safariInspectionInstructionsSeen") }
    }
    var globalSearchEnabled: Bool {
        get { value("globalSearchEnabled") as? Bool ?? false }
        set { set(newValue, "globalSearchEnabled") }
    }
    var quickHideEnabled: Bool {
        get { value("quickHideEnabled") as? Bool ?? false }
        set { set(newValue, "quickHideEnabled") }
    }
    var searchHotKey: BrowserHotKey {
        get { BrowserHotKey(key: (value("searchKey") as? NSNumber)?.uint32Value ?? 49, modifiers: (value("searchModifiers") as? NSNumber)?.uint32Value ?? 6144, label: value("searchKeyLabel") as? String ?? "⌃⌥Space") }
        set { set(newValue.key, "searchKey"); set(newValue.modifiers, "searchModifiers"); set(newValue.label, "searchKeyLabel") }
    }
    var hideHotKey: BrowserHotKey {
        get { BrowserHotKey(key: (value("hideKey") as? NSNumber)?.uint32Value ?? 4, modifiers: (value("hideModifiers") as? NSNumber)?.uint32Value ?? 768, label: value("hideKeyLabel") as? String ?? "⌘⇧H") }
        set { set(newValue.key, "hideKey"); set(newValue.modifiers, "hideModifiers"); set(newValue.label, "hideKeyLabel") }
    }
    var showContentFrame: Bool {
        get { value("contentFrame") as? Bool ?? true }
        set { set(newValue, "contentFrame") }
    }
    var sidebarBehavior: SidebarBehavior {
        get { (value("sidebarBehavior") as? String).flatMap(SidebarBehavior.init(rawValue:)) ?? .visible }
        set { set(newValue.rawValue, "sidebarBehavior") }
    }
    var braveSuggestions: Bool {
        get { value("braveSuggestions") as? Bool ?? true }
        set { set(newValue, "braveSuggestions") }
    }
    var privateBraveSuggestions: Bool {
        get { value("privateBraveSuggestions") as? Bool ?? false }
        set { set(newValue, "privateBraveSuggestions") }
    }
    func allowsRemoteSuggestions(isPrivate: Bool) -> Bool { isPrivate ? privateBraveSuggestions : braveSuggestions }
    var onboardingComplete: Bool {
        get { value("onboardingComplete") as? Bool ?? false }
        set { set(newValue, "onboardingComplete") }
    }
    var privacy: String {
        get { value("privacy") as? String ?? "standard" }
        set { set(newValue, "privacy") }
    }
    var compactBookmarks: Bool {
        get { value("compactBookmarks") as? Bool ?? false }
        set { set(newValue, "compactBookmarks") }
    }
    var showBookmarkBar: Bool {
        get { value("bookmarkBar") as? Bool ?? false }
        set { set(newValue, "bookmarkBar") }
    }
    var automaticSleeping: Bool {
        get { value("automaticSleeping") as? Bool ?? false }
        set { set(newValue, "automaticSleeping") }
    }
    var askDownloadDestination: Bool {
        get { value("askDownloadDestination") as? Bool ?? true }
        set { set(newValue, "askDownloadDestination") }
    }
    var downloadDirectoryBookmark: Data? {
        get { value("downloadDirectoryBookmark") as? Data }
        set { set(newValue ?? Data(), "downloadDirectoryBookmark") }
    }
    var currentProfileID: UUID {
        get { (value("profile") as? String).flatMap(UUID.init(uuidString:)) ?? BrowserProfile.defaultID }
        set { set(newValue.uuidString, "profile") }
    }
    private var appearances: [UUID: Personalization] = [:]
    private let transientAppearanceDomain = "Origami.TransientAppearance." + UUID().uuidString
    deinit { if defaults == nil { UserDefaults.standard.removePersistentDomain(forName: transientAppearanceDomain) } }
    @MainActor func appearance(for id: UUID) -> Personalization {
        if id == BrowserProfile.defaultID, defaults === UserDefaults.standard { return .shared }
        if let existing = appearances[id] { return existing }
        let result = Personalization(defaults: defaults ?? UserDefaults(suiteName: transientAppearanceDomain)!,
            prefix: id == BrowserProfile.defaultID ? "" : "profile." + id.uuidString + ".")
        appearances[id] = result
        return result
    }
    @MainActor func removeProfilePreferences(_ id: UUID) {
        appearances.removeValue(forKey: id)
        let prefix = "profile." + id.uuidString + "."
        let storage = defaults ?? UserDefaults(suiteName: transientAppearanceDomain)!
        for key in storage.dictionaryRepresentation().keys where key.hasPrefix(prefix) { storage.removeObject(forKey: key) }
        defaults?.removeObject(forKey: "browser.layout." + id.uuidString)
        values.removeValue(forKey: "layout." + id.uuidString)
    }
    func profileLayout(_ id: UUID) -> TabLayout {
        if value("layout." + id.uuidString) == nil { setProfileLayout(layout, for: id) }
        return (value("layout." + id.uuidString) as? String).flatMap(TabLayout.init(rawValue:)) ?? layout
    }
    func setProfileLayout(_ layout: TabLayout, for id: UUID) {
        set(layout.rawValue, "layout." + id.uuidString)
    }
    var layout: TabLayout {
        get { (value("layout") as? String).flatMap(TabLayout.init(rawValue:)) ?? .horizontal }
        set { set(newValue.rawValue, "layout") }
    }
    var searchEngine: SearchEngine {
        get { (value("search") as? String).flatMap(SearchEngine.init(rawValue:)) ?? .google }
        set { set(newValue.rawValue, "search") }
    }
    var restoreSession: Bool {
        get { value("restore") as? Bool ?? true }
        set { set(newValue, "restore") }
    }
    func apply(to session: inout BrowserSession) {
        session.layout = layout; session.searchEngine = searchEngine; session.restoreSession = restoreSession
    }
    func save(_ session: BrowserSession) {
        currentProfileID = session.profileID
        layout = session.layout; searchEngine = session.searchEngine; restoreSession = session.restoreSession
    }
}
