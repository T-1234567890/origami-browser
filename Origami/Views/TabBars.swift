import SwiftUI

struct TabBars: View {
    let store: BrowserStore
    let vertical: Bool
    var emptySpaceClicked: (() -> Void)? = nil
    var sidebarFooter: AnyView? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frozenTabWidth: CGFloat?
    @State private var splitMemberFrames: [UUID: CGRect] = [:]
    @State private var tabFrames: [UUID: CGRect] = [:]
    @State private var draggedTab: UUID?
    @State private var draggedGroup: UUID?
    @State private var dragLocation = CGPoint.zero
    @State private var groupFrames: [UUID: CGRect] = [:]
    @State private var barFrame = CGRect.zero
    @State private var dropTarget: TabDropTarget?
    @State private var measuredStripWidth: CGFloat = 0
    @State private var frozenStripWidth: CGFloat?
    @State private var editingGroup: UUID?
    @State private var groupName = ""
    @State private var groupColor = TabGroupColor.purple
    @State private var showingGroupName = false

    private var pinnedTabs: [BrowserTab] { store.session.tabs.filter { $0.isPinned && store.session.visibleTabIDs.contains($0.id) } }
    private var ungroupedTabs: [BrowserTab] { store.session.tabs.filter { !$0.isPinned && $0.groupID == nil && store.session.visibleTabIDs.contains($0.id) } }
    private var scrollTarget: UUID? {
        let anchorID = store.session.selectedTabID == store.session.split?.right ? store.session.split?.left : store.session.selectedTabID
        if let groupID = store.session.tabs.first(where: { $0.id == anchorID })?.groupID,
           store.session.groups.contains(where: { $0.id == groupID && $0.isCollapsed }) { return groupID }
        return anchorID
    }

    var body: some View {
        Group {
            if vertical { verticalBar }
            else { horizontalBar }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: store.session.groups.map(\.isCollapsed))
        .onPreferenceChange(SplitMemberFramePreference.self) { splitMemberFrames = $0 }
        .onPreferenceChange(TabFramePreference.self) { tabFrames = $0 }
        .onPreferenceChange(GroupFramePreference.self) { groupFrames = $0 }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { barFrame = $0 }
        .simultaneousGesture(DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                if draggedTab == nil && draggedGroup == nil {
                    draggedGroup = groupFrames.first(where: { $0.value.contains(value.startLocation) })?.key
                    draggedTab = splitMemberFrames.first(where: { $0.value.contains(value.startLocation) })?.key
                        ?? tabFrames.first(where: { $0.value.contains(value.startLocation) })?.key
                }
                guard draggedTab != nil || draggedGroup != nil else { return }
                dragLocation = value.location
                dropTarget = target(at: value.location)
            }
            .onEnded { value in
                if let draggedTab, splitMemberFrames[draggedTab] != nil {
                    let combined = splitMemberFrames.values.reduce(CGRect.null) { $0.union($1) }
                    if !combined.insetBy(dx: -8, dy: -8).contains(value.location) {
                        store.detachSplitTab(draggedTab, target: target(at: value.location))
                    }
                } else if let target = target(at: value.location) {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                        if let draggedGroup { store.dropGroup(draggedGroup, target: target) }
                        else if let draggedTab { store.dropTab(draggedTab, target: target) }
                    }
                }
                draggedTab = nil; draggedGroup = nil; dropTarget = nil
            })
        .overlay(alignment: .topLeading) {
            if draggedTab != nil || draggedGroup != nil {
                dragPreview
                    .offset(x: dragLocation.x - barFrame.minX + 12, y: dragLocation.y - barFrame.minY + 12)
                    .allowsHitTesting(false)
            }
        }
        .preference(key: SidebarPopoverPreference.self, value: showingGroupName || draggedTab != nil || draggedGroup != nil)
    }

    private var dragPreview: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(draggedGroup.flatMap { id in store.session.groups.first { $0.id == id }?.name }
                 ?? draggedTab.flatMap { id in store.session.tabs.first { $0.id == id }?.title } ?? "Tab")
                .font(.system(size: 12, weight: .medium)).lineLimit(1)
            Text(dropDescription).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(9).frame(width: 170, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }

    private var dropDescription: String {
        switch dropTarget {
        case .group(let id):
            let name = store.session.groups.first { $0.id == id }?.name ?? "group"
            return draggedGroup == nil ? "Add to \(name)" : "Move before \(name)"
        case .tab(_, let after): return after ? "Move after tab" : "Move before tab"
        case .end: return "Move to end"
        case nil:
            return draggedTab.flatMap { splitMemberFrames[$0] } != nil ? "Drag out to separate tabs" : "Release to cancel"
        }
    }

    private func target(at point: CGPoint) -> TabDropTarget? {
        guard barFrame.contains(point), draggedTab != nil || draggedGroup != nil else { return nil }
        if let group = groupFrames.first(where: { $0.value.contains(point) }) {
            guard group.key != draggedGroup,
                  draggedTab.flatMap({ id in store.session.tabs.first { $0.id == id }?.isPinned }) != true else { return nil }
            return .group(group.key)
        }
        if let hit = tabFrames.first(where: { $0.value.contains(point) }),
           let tab = store.session.tabs.first(where: { $0.id == hit.key }) {
            if tab.id == draggedTab || (draggedGroup != nil && tab.groupID == draggedGroup) { return nil }
            if draggedGroup != nil && tab.isPinned { return nil }
        }
        // Resolve the spaces between rows to the nearest row, rather than unexpectedly jumping to the end.
        let frames = tabFrames.filter { entry in
            guard let tab = store.session.tabs.first(where: { $0.id == entry.key }) else { return false }
            if draggedGroup != nil { return !tab.isPinned && tab.groupID != draggedGroup }
            return tab.isPinned == store.session.tabs.first(where: { $0.id == draggedTab })?.isPinned
        }
        let position = vertical ? point.y : point.x
        if let tab = frames.min(by: {
            abs(position - (vertical ? $0.value.midY : $0.value.midX)) < abs(position - (vertical ? $1.value.midY : $1.value.midX))
        }) {
            let end = frames.values.map { vertical ? $0.maxY : $0.maxX }.max() ?? 0
            if position > end + 12 { return draggedTab.flatMap { id in store.session.tabs.first { $0.id == id }?.isPinned } == true ? nil : .end }
            guard tab.key != draggedTab else { return nil }
            return .tab(tab.key, after: position > (vertical ? tab.value.midY : tab.value.midX))
        }
        return .end
    }

    private var verticalBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                GeometryReader { viewport in
                    ScrollView {
                        VStack(alignment: .leading, spacing: BrowserChromeMetrics.tabSpacing) {
                            ForEach(store.session.tabStripItems) { item in
                                switch item {
                                case .tab(let tab): row(tab)
                                case .group(let group): groupHeader(group).padding(.top, 6)
                                }
                            }
                            HStack(spacing: 4) { newTabButton; newGroupButton }
                                .padding(.trailing, 8).padding(.top, 4)
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                        .frame(minHeight: viewport.size.height, alignment: .topLeading)
                        .background {
                            Color.clear.contentShape(Rectangle())
                                .onTapGesture { emptySpaceClicked?() }
                        }
                        .animation(reduceMotion ? nil : .linear(duration: 0.18), value: store.session.tabs.map(\.id))
                    }
                    .onChange(of: scrollTarget, initial: true) {
                        if draggedTab == nil, draggedGroup == nil, frozenTabWidth == nil, let id = scrollTarget { proxy.scrollTo(id) }
                    }
                }
            }
            if let sidebarFooter { sidebarFooter }
            if store.isPrivate || !pinnedTabs.isEmpty {
                ChromeHairline().padding(.horizontal, 10)
                if store.isPrivate {
                    Label("Private", systemImage: "lock.fill")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: BrowserChromeMetrics.pinnedHeight, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .accessibilityLabel("Private browsing window")
                }
                if !pinnedTabs.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(pinnedTabs) { tab in row(tab) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .accessibilityLabel("Pinned Tabs")
                    .transition(reduceMotion ? .identity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: pinnedTabs.map(\.id))
        .frame(minWidth: BrowserChromeMetrics.sidebarWidthRange.lowerBound, idealWidth: 240,
               maxWidth: BrowserChromeMetrics.sidebarWidthRange.upperBound, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("verticalTabs")
    }

    private var horizontalBar: some View {
        HStack(spacing: 4) {
            GeometryReader { geometry in
                let tabWidth = frozenTabWidth ?? horizontalTabWidth(availableWidth: geometry.size.width)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(alignment: .bottom, spacing: BrowserChromeMetrics.tabSpacing) {
                            ForEach(pinnedTabs) { tab in row(tab, width: tabWidth) }
                            if !pinnedTabs.isEmpty {
                                Color(nsColor: .separatorColor).opacity(0.45)
                                    .frame(width: 1, height: 12).padding(.horizontal, 4)
                                    .accessibilityHidden(true)
                            }
                            ForEach(store.session.tabStripItems) { item in
                                switch item {
                                case .tab(let tab): row(tab, width: tabWidth)
                                case .group(let group): groupHeader(group, width: tabWidth)
                                }
                            }
                            newTabButton
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measuredStripWidth = $0 }
                        .frame(minWidth: frozenStripWidth, alignment: .leading)
                        .padding(.top, BrowserChromeMetrics.stripHeight - (pinnedTabs.isEmpty ? BrowserChromeMetrics.tabHeight : BrowserChromeMetrics.horizontalPinnedHeight))
                        .animation(reduceMotion ? nil : .linear(duration: 0.18), value: store.session.tabs.map(\.id))
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: scrollTarget, initial: true) {
                        if draggedTab == nil, draggedGroup == nil, frozenTabWidth == nil, let id = scrollTarget { proxy.scrollTo(id) }
                    }
                    .onChange(of: geometry.size.width) {
                        frozenTabWidth = nil
                        frozenStripWidth = nil
                        if draggedTab == nil, draggedGroup == nil, frozenTabWidth == nil, let id = scrollTarget { proxy.scrollTo(id) }
                    }
                }
            }
            newGroupButton
                .frame(height: BrowserChromeMetrics.stripHeight, alignment: .bottom)
        }
        .padding(.horizontal, 8)
        .frame(height: BrowserChromeMetrics.stripHeight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("horizontalTabs")
        .onHover { inside in
            if !inside {
                withAnimation(reduceMotion ? nil : .linear(duration: 0.18)) {
                    frozenTabWidth = nil
                    frozenStripWidth = nil
                }
            }
        }
    }

    private func tabs(in group: TabGroup) -> [BrowserTab] {
        store.session.tabs.filter { $0.groupID == group.id }
    }

    private func horizontalTabWidth(availableWidth: CGFloat) -> CGFloat {
        let regularCount = ungroupedTabs.count + store.session.groups.filter { !$0.isCollapsed }.reduce(0) { $0 + tabs(in: $1).filter { store.session.visibleTabIDs.contains($0.id) }.count }
        let pinCount = pinnedTabs.count
        let groupCount = store.session.groups.count
        let separatorCount = pinCount == 0 ? 0 : 1
        let itemCount = regularCount + pinCount + groupCount + separatorCount
        let reserved = CGFloat(24) + BrowserChromeMetrics.tabSpacing + CGFloat(pinCount) * BrowserChromeMetrics.pinnedWidth
            + CGFloat(separatorCount) * 9
            + CGFloat(max(0, itemCount - 1)) * BrowserChromeMetrics.tabSpacing
        let width = (availableWidth - reserved) / CGFloat(max(1, regularCount + groupCount))
        return min(BrowserChromeMetrics.maximumTabWidth, max(BrowserChromeMetrics.minimumTabWidth, width))
    }

    private var newTabButton: some View {
        Button { store.newTab() } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus").frame(width: 14)
                if vertical { Text("New Tab"); Spacer(minLength: 0) }
            }
            .padding(.horizontal, 6)
            .frame(height: BrowserChromeMetrics.tabHeight)
            .contentShape(Rectangle())
        }
        .font(.system(size: 11)).foregroundStyle(.secondary).buttonStyle(.plain)
        .help("New Tab (⌘T)").accessibilityLabel("New Tab")
    }
    private var newGroupButton: some View {
        Button { editingGroup = nil; groupName = ""; groupColor = .purple; showingGroupName = true } label: {
            Image(systemName: "folder.badge.plus").frame(width: 22, height: 24)
        }
        .font(.system(size: 11)).foregroundStyle(.secondary).buttonStyle(.plain)
        .help("New Tab Group").accessibilityLabel("New Tab Group")
        .popover(isPresented: groupEditorPresented(for: nil)) { groupEditor }
    }

    private func groupHeader(_ group: TabGroup, width: CGFloat? = nil) -> some View {
        let tint = group.tint
        return Button { store.toggleGroup(group.id) } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(group.isCollapsed ? 0 : 90))
                    .font(.system(size: 9, weight: .semibold))
                Text(group.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if group.isCollapsed { Text("\(tabs(in: group).count)").font(.system(size: 10)).opacity(0.7) }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 9).frame(height: 20)
            .frame(width: vertical ? nil : width, alignment: .leading)
            .frame(maxWidth: vertical ? .infinity : nil, alignment: .leading)
            .background(tint, in: RoundedRectangle(cornerRadius: 5))
            .overlay {
                if dropTarget == .group(group.id) {
                    RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.8), lineWidth: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(draggedGroup == group.id ? 0.4 : 1)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: GroupFramePreference.self, value: [group.id: geometry.frame(in: .global)])
            }
        }
        .frame(maxWidth: vertical ? .infinity : nil, alignment: .leading)
        .id(group.id)
        .help(group.name + " · Click to collapse; drag to move group; drop tabs on this title to join")
        .accessibilityLabel(group.name)
        .accessibilityValue(group.isCollapsed ? "Collapsed" : "Expanded")
        .popover(isPresented: groupEditorPresented(for: group.id)) { groupEditor }
        .contextMenu {
            Button("Bookmark Group") { store.bookmarkTabs(tabs(in: group), name: group.name) }
            Button("New Tab in Group") { store.newTab(groupID: group.id) }
            Button("Rename Group…") { editingGroup = group.id; groupName = group.name; groupColor = (group.color ?? .purple).permitted; showingGroupName = true }
            Menu("Color") {
                Picker("Color", selection: Binding(get: { (group.color ?? .purple).permitted }, set: { store.setGroupColor(group.id, color: $0) })) {
                    ForEach(TabGroupColor.selectable, id: \.self) { color in
                        Label { Text(color.title) } icon: { Image(nsImage: color.menuSwatch).renderingMode(.original) }.tag(color)
                    }
                }.pickerStyle(.inline)
            }
            Button("Ungroup Tabs") { store.removeGroup(group.id) }
        }
    }

    private func groupEditorPresented(for id: UUID?) -> Binding<Bool> {
        Binding(get: { showingGroupName && editingGroup == id },
                set: { if !$0 && editingGroup == id { showingGroupName = false } })
    }

    private var groupEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editingGroup == nil ? "New Tab Group" : "Rename Group").font(.headline)
            TextField("Group name", text: $groupName).onSubmit(saveGroup)
            Text("Color").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 7) {
                ForEach(TabGroupColor.selectable, id: \.self) { color in
                    Button { groupColor = color } label: {
                        Circle().fill(color.tint).frame(width: 22, height: 22)
                            .overlay { if groupColor == color { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) } }
                    }.buttonStyle(.plain).help(color.title).accessibilityLabel(color.title)
                        .accessibilityAddTraits(groupColor == color ? .isSelected : [])
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { showingGroupName = false }.keyboardShortcut(.cancelAction)
                Button("Save", action: saveGroup).keyboardShortcut(.defaultAction)
                    .disabled(groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(16).frame(width: 260)
    }

    private func saveGroup() {
        guard !groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let id: UUID
        if let editingGroup { store.renameGroup(editingGroup, name: groupName); id = editingGroup }
        else { id = store.createGroup(name: groupName) }
        store.setGroupColor(id, color: groupColor)
        showingGroupName = false
    }

    private func combinedRow(_ left: BrowserTab, _ right: BrowserTab, width: CGFloat?) -> some View {
        HStack(spacing: 0) {
            splitMember(left)
            Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 1, height: 16)
            splitMember(right)
        }
        .frame(width: vertical ? nil : width, height: BrowserChromeMetrics.tabHeight)
        .frame(maxWidth: vertical ? .infinity : nil)
        .background(store.session.activeSplit != nil ? Personalization.shared.accent.opacity(0.18) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        .contextMenu {
            Button("Separate Tabs") { store.endSplit() }
            Button("Swap Split Sides") { store.swapSplit() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Split tabs: \(left.title), \(right.title)")
    }

    private func splitMember(_ tab: BrowserTab) -> some View {
        HStack(spacing: 0) {
        Button { store.select(tab.id) } label: {
            HStack(spacing: 4) {
                SiteIcon(store: store, url: tab.url, size: 14)
                Text(tab.title).font(.system(size: 11, weight: store.session.selectedTabID == tab.id ? .medium : .regular)).lineLimit(1)
            }.frame(maxWidth: .infinity, minHeight: BrowserChromeMetrics.tabHeight)
                .padding(.horizontal, 6).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .help(tab.title + " · Drag out to separate tabs")
            .accessibilityLabel(tab.title)
            .accessibilityIdentifier("tab-\(tab.id)")
            Button { store.close(tab.id) } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .medium)).frame(width: 20, height: 24)
            }.buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Close " + tab.title).accessibilityLabel("Close " + tab.title)
        }
            .frame(maxWidth: .infinity)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: SplitMemberFramePreference.self, value: [tab.id: geometry.frame(in: .global)])
                }
            }
    }

    private func row(_ tab: BrowserTab, width: CGFloat? = nil) -> some View {
        Group {
        if let split = store.session.split, split.left == tab.id,
           let right = store.session.tabs.first(where: { $0.id == split.right }) {
            combinedRow(tab, right, width: width)
        } else {
        TabRow(store: store, tab: tab, vertical: vertical, width: width, close: {
            // Keep the next close button under the pointer while closing a run of tabs.
            if !vertical {
                frozenTabWidth = width
                if frozenStripWidth == nil { frozenStripWidth = measuredStripWidth }
            }
            withAnimation(reduceMotion ? nil : .linear(duration: 0.18)) { store.close(tab.id) }
        })
        }
        }
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: TabFramePreference.self, value: [tab.id: geometry.frame(in: .global)])
            }
        }
        .opacity(draggedTab == tab.id || (draggedGroup != nil && tab.groupID == draggedGroup) ? 0.4 : 1)
        .overlay {
            if case .tab(let id, _) = dropTarget, id == tab.id {
                RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)).allowsHitTesting(false)
            }
        }
        .transition(reduceMotion ? .identity : .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.96)), removal: .opacity))
        .id(tab.id)
    }
}

private struct TabFramePreference: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct GroupFramePreference: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct SplitMemberFramePreference: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}
