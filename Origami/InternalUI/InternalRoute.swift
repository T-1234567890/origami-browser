import Foundation

enum InternalPage: String, CaseIterable {
    case feeds, newtab, history, bookmarks, downloads, settings, data, permissions, profiles, welcome
    var url: URL { URL(string: "origami://" + rawValue)! }
    var title: String {
        switch self {
        case .feeds: return "Websites I Follow"
        case .newtab: return "New Tab"
        case .data: return "Website Data"
        default: return rawValue.capitalized
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
