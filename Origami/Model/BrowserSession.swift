import Foundation

enum TabLayout: String, Codable, CaseIterable { case horizontal, vertical }
struct BrowserTab: Identifiable, Codable, Equatable {
    var id = UUID()
    var url: URL?
    var title = "New Tab"
    var isPinned = false
    var groupID: UUID?
    var isSleeping: Bool?
    var canReopen: Bool { url.map { ["http", "https"].contains($0.scheme?.lowercased() ?? "") } ?? false }
}
enum TabGroupColor: String, Codable, CaseIterable {
    // Legacy cases remain decodable so existing sessions are not lost.
    case accent, blue, purple, pink, red, orange, green, teal
    static let selectable: [Self] = [.purple, .pink, .red, .orange, .green, .teal]
    var permitted: Self { Self.selectable.contains(self) ? self : .purple }
}
struct TabGroup: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var isCollapsed = false
    var color: TabGroupColor?
    var anchorIndex: Int?
}
struct BrowserSplit: Codable, Equatable, Hashable {
    var left: UUID
    var right: UUID
}

struct BrowserSession: Codable, Equatable {
    static let maximumPinnedTabs = 6
    var id = UUID()
    var windowID = UUID()
    var profileID = BrowserProfile.defaultID
    var windowFrame: String?
    var split: BrowserSplit?
    var version = 1
    var tabs: [BrowserTab] = [BrowserTab()]
    var selectedTabID: UUID?
    var groups: [TabGroup] = []
    var layout: TabLayout = .horizontal
    var searchEngine: SearchEngine = .google
    var restoreSession = true

    mutating func normalize() {
        var ids = Set<UUID>()
        tabs = tabs.filter { ids.insert($0.id).inserted }
        var groupIDs = Set<UUID>()
        groups = groups.filter { groupIDs.insert($0.id).inserted }
        for index in groups.indices { groups[index].color = (groups[index].color ?? .purple).permitted }
        var pinnedCount = 0
        for index in tabs.indices {
            if tabs[index].isPinned {
                pinnedCount += 1
                if pinnedCount > Self.maximumPinnedTabs { tabs[index].isPinned = false }
            }
            if tabs[index].isPinned { tabs[index].groupID = nil }
            if let groupID = tabs[index].groupID, !groupIDs.contains(groupID) { tabs[index].groupID = nil }
        }
        if let split, split.left == split.right || !tabs.contains(where: { $0.id == split.left }) || !tabs.contains(where: { $0.id == split.right }) { self.split = nil }
        tabs = tabs.filter(\.isPinned) + tabs.filter { !$0.isPinned }
        if !tabs.contains(where: { $0.id == selectedTabID }) { selectedTabID = tabs.first?.id }
    }
}

extension BrowserSession {
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? id
        windowID = try values.decodeIfPresent(UUID.self, forKey: .windowID) ?? windowID
        profileID = try values.decodeIfPresent(UUID.self, forKey: .profileID) ?? profileID
        split = try values.decodeIfPresent(BrowserSplit.self, forKey: .split)
        windowFrame = try values.decodeIfPresent(String.self, forKey: .windowFrame)
        tabs = try values.decode([BrowserTab].self, forKey: .tabs)
        groups = try values.decode([TabGroup].self, forKey: .groups)
        selectedTabID = try values.decodeIfPresent(UUID.self, forKey: .selectedTabID)
        layout = try values.decode(TabLayout.self, forKey: .layout)
        searchEngine = try values.decode(SearchEngine.self, forKey: .searchEngine)
        restoreSession = try values.decode(Bool.self, forKey: .restoreSession)
    }
}
