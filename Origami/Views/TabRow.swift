import SwiftUI

struct TabRow: View {
    let store: BrowserStore
    let tab: BrowserTab
    let vertical: Bool
    let width: CGFloat?
    var close: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    private var active: Bool { store.session.selectedTabID == tab.id }
    private var rowHeight: CGFloat { tab.isPinned ? (vertical ? BrowserChromeMetrics.pinnedHeight : BrowserChromeMetrics.horizontalPinnedHeight) : BrowserChromeMetrics.tabHeight }
    private var showsClose: Bool { active || hovered }
    private var tabShape: UnevenRoundedRectangle {
        if tab.isPinned { return UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8, bottomTrailingRadius: 8, topTrailingRadius: 8) }
        return UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: vertical ? 6 : 0,
                               bottomTrailingRadius: vertical ? 6 : 0, topTrailingRadius: 6)
    }

    var body: some View {
        HStack(spacing: 2) {
            Button { store.select(tab.id) } label: {
                HStack(spacing: 6) {
                    if !tab.isPinned, let group = store.session.groups.first(where: { $0.id == tab.groupID }) {
                        RoundedRectangle(cornerRadius: 1).fill(group.tint).frame(width: 3, height: 15)
                            .accessibilityLabel("Group: \(group.name)")
                    }
                    if tab.isPinned { SiteIcon(store: store, url: tab.url, size: vertical ? 20 : 16) }
                    else { TabIcon(store: store, tab: tab) }
                    if !tab.isPinned {
                        Text(tab.title).font(.system(size: 11, weight: active ? .medium : .regular)).contentTransition(.opacity).animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: tab.title)
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tab-\(tab.id)")
            .accessibilityLabel(tab.title)
            .accessibilityValue(tab.isPinned ? (active ? "Pinned, selected" : "Pinned") : (active ? "Selected" : ""))
            if !tab.isPinned {
                Button { if let close { close() } else { store.close(tab.id) } } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .medium)).frame(width: 16, height: 22)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .opacity(showsClose ? 1 : 0)
                .allowsHitTesting(showsClose)
                .accessibilityHidden(!showsClose)
                .accessibilityLabel("Close \(tab.title)").help("Close Tab")
            }
        }
        .padding(.horizontal, tab.isPinned ? 0 : 6)
        .frame(width: tab.isPinned ? (vertical ? BrowserChromeMetrics.verticalPinnedWidth : BrowserChromeMetrics.pinnedWidth) : width,
               height: rowHeight)
        .background {
            tabShape
                .fill(active && !tab.isPinned ? Personalization.shared.accent.opacity(0.24) : (active && tab.isPinned ? Personalization.shared.accent.opacity(hovered ? 0.22 : 0.14) : Color.primary.opacity(hovered ? 0.08 : 0)))
        }
        .overlay(alignment: vertical ? .leading : .top) {
            if vertical && active && !tab.isPinned {
                Rectangle().fill(Personalization.shared.accent)
                    .frame(width: vertical ? 2 : nil, height: vertical ? nil : 2)
                    .allowsHitTesting(false)
            }
        }
        .clipShape(tabShape)
        .animation(reduceMotion ? nil : .linear(duration: 0.16), value: active)
        .animation(reduceMotion ? nil : .linear(duration: 0.12), value: hovered)
        .onHover { hovered = $0 }
        .help((tab.isPinned ? "Pinned: " : "") + tab.title + (tab.url.map { "\n" + $0.absoluteString } ?? ""))
        .contextMenu {
            Menu("Split with Tab") {
                ForEach(store.session.tabs.filter { $0.id != tab.id }) { other in
                    Button(other.title) { store.select(tab.id); store.splitWith(other.id) }
                }
            }.disabled(store.session.tabs.count < 2)
            if store.session.split != nil {
                Button("Replace Left Side") { store.replaceSplitSide(true, with: tab.id) }
                Button("Replace Right Side") { store.replaceSplitSide(false, with: tab.id) }
                Button("Swap Split Sides") { store.swapSplit() }
                Button("End Split") { store.endSplit() }
            }

            Button(tab.isSleeping == true ? "Wake Tab" : "Sleep Tab") { if tab.isSleeping == true { store.wake(tab.id) } else { Task { await store.sleep(tab.id) } } }
                .disabled(tab.isPinned)
            Button("Never Sleep This Site") { store.neverSleep(tab) }.disabled(tab.url?.host == nil)
            Button("Bookmark Tab") { if let url = tab.url { do { _ = try store.services?.bookmarks.addUnique(url: url, title: tab.title, profileID: store.session.profileID); store.bookmarkRevision += 1 } catch { store.persistenceError = error.localizedDescription } } }
            if !store.isPrivate, let app = store.application {
                Menu("Move to Window") {
                    ForEach(app.stores.values.filter { $0 !== store && !$0.isPrivate && $0.session.profileID == store.session.profileID }.sorted { $0.session.windowID.uuidString < $1.session.windowID.uuidString }, id: \.session.windowID) { target in
                        Button(target.selectedTab?.title ?? "Window") { app.moveTab(tab.id, from: store, to: target) }
                    }
                    Button("New Window") { let target = app.newWindow(profileID: store.session.profileID); app.moveTab(tab.id, from: store, to: target) }
                }
            }
            Divider()
            Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") { store.togglePin(tab.id) }
                .disabled(!tab.isPinned && store.profilePinCount >= BrowserSession.maximumPinnedTabs)
            Button("Duplicate Tab") { store.duplicate(tab.id) }
            Menu("Move to Group") {
                Button("No Group") { store.setGroup(tab.id, groupID: nil) }
                ForEach(store.session.groups) { group in
                    Button(group.name) { store.setGroup(tab.id, groupID: group.id) }
                }
                Divider()
                Button("New Group with Tab") { store.createGroup(name: "New Group", tabID: tab.id) }
            }
            Divider()
            Button(vertical ? "Move Up" : "Move Left") { store.moveBy(tab.id, offset: -1) }
            Button(vertical ? "Move Down" : "Move Right") { store.moveBy(tab.id, offset: 1) }
            Divider()
            Button("Close Tab") { store.close(tab.id) }
        }
    }
}

private struct TabIcon: View {
    let store: BrowserStore
    let tab: BrowserTab
    private var page: TabPage? { store.loadedPage(for: tab.id) }
    var body: some View {
        Group {
            if tab.isSleeping == true { Image(systemName: "moon.zzz").foregroundStyle(.secondary) }
            else if page?.mediaState.isPlayingMedia == true && page?.mediaState.isMuted == true { Image(systemName: "speaker.slash.fill").accessibilityLabel("Muted") }
            else if page?.mediaState.isPlayingMedia == true { Image(systemName: "speaker.wave.2.fill").accessibilityLabel("Playing") }
            else if page?.isLoading == true { ProgressView().controlSize(.mini) }
            else if let icon = page?.favicon { Image(nsImage: icon).resizable().scaledToFit() }
            else if tab.url == nil { Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary) }
            else { SiteIcon(store: store, url: tab.url, size: 14) }
        }.frame(width: 14, height: 14)
    }
}
