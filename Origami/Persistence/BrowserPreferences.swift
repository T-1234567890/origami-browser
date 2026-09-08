import Foundation

final class BrowserPreferences {
    private let defaults: UserDefaults?
    private var values: [String: Any] = [:]
    init(defaults: UserDefaults? = nil) { self.defaults = defaults }
    private func value(_ key: String) -> Any? { defaults?.object(forKey: "browser." + key) ?? values[key] }
    private func set(_ value: Any, _ key: String) {
        if let defaults { defaults.set(value, forKey: "browser." + key) } else { values[key] = value }
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
