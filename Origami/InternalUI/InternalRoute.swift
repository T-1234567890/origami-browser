import Foundation

enum InternalPage: String, CaseIterable {
    case feeds, newtab, history, bookmarks, downloads, settings, data, permissions, profiles, welcome, scripts, credits, migration
    var url: URL { URL(string: "origami://" + rawValue)! }
    /// Shared SF Symbols for native destinations, including unloaded and pinned tabs.
    var symbol: String {
        switch self {
        case .newtab: "magnifyingglass"
        case .history: "clock"
        case .bookmarks: "book"
        case .downloads: "arrow.down.circle"
        case .settings: "gearshape"
        case .feeds: "dot.radiowaves.left.and.right"
        case .data: "externaldrive"
        case .permissions: "hand.raised"
        case .profiles: "person.crop.circle"
        case .welcome: "hand.wave"
        case .scripts: "curlybraces"
        case .credits: "text.book.closed"
        case .migration: "square.and.arrow.down"
        }
    }
    var title: String {
        switch self {
        case .feeds: return L10n.string("Websites I Follow")
        case .newtab: return L10n.string("New Tab")
        case .data: return L10n.string("Website Data")
        case .credits: return L10n.string("Credits & Licenses")
        case .migration: return L10n.string("Import Browser Data")
        default: return L10n.string(rawValue.capitalized)
        }
    }
}
enum InternalRoute {
    static let newTabURL = URL(string: "origami://newtab")!
    static func page(for url: URL) -> InternalPage? {
        guard url.scheme == "origami", url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/",
              let host = url.host, let page = InternalPage(rawValue: host),
              url.absoluteString == "origami://\(host)" || url.absoluteString == "origami://\(host)/" else { return nil }
        return page
    }
}
