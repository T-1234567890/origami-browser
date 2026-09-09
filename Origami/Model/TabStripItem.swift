import Foundation

enum TabDropTarget: Equatable { case group(UUID), tab(UUID, after: Bool), end }

enum TabStripItem: Identifiable {
    case tab(BrowserTab), group(TabGroup)
    var id: UUID { switch self { case .tab(let tab): tab.id; case .group(let group): group.id } }
}
extension BrowserSession {
    var activeSplit: BrowserSplit? {
        guard let split, selectedTabID == split.left || selectedTabID == split.right else { return nil }
        return split
    }
    var visibleTabIDs: Set<UUID> { Set(tabs.map(\.id).filter { $0 != split?.right }) }

    // The stored tab order is shared by both layouts. Ungrouped tabs are not hoisted above groups.
    var tabStripItems: [TabStripItem] {
        var items: [TabStripItem] = []
        var anchors: [Int: [TabGroup]] = [:]
        for group in groups {
            let index = tabs.firstIndex { $0.groupID == group.id } ?? min(max(group.anchorIndex ?? tabs.count, 0), tabs.count)
            anchors[index, default: []].append(group)
        }
        for index in 0...tabs.count {
            for group in anchors[index] ?? [] { items.append(.group(group)) }
            guard index < tabs.count, !tabs[index].isPinned else { continue }
            let tab = tabs[index]
            guard visibleTabIDs.contains(tab.id) else { continue }
            if !groups.contains(where: { $0.id == tab.groupID && $0.isCollapsed }) { items.append(.tab(tab)) }
        }
        return items
    }
}
