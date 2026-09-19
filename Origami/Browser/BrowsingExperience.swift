import Foundation
import AppKit
import CoreGraphics

struct PageSplitDropTarget: Equatable {
    let pageID: UUID
    let onLeft: Bool
}

extension BrowserStore {
    func pageSplitTarget(for draggedID: UUID, at point: CGPoint) -> PageSplitDropTarget? {
        guard session.tabs.contains(where: { $0.id == draggedID }),
              let hit = pageDropFrames.first(where: { $0.value.contains(point) }),
              hit.key != draggedID, session.tabs.contains(where: { $0.id == hit.key }) else { return nil }
        return PageSplitDropTarget(pageID: hit.key, onLeft: point.x < hit.value.midX)
    }

    func dropTabIntoPage(_ id: UUID, target: PageSplitDropTarget) {
        guard id != target.pageID,
              session.tabs.contains(where: { $0.id == id }),
              session.tabs.contains(where: { $0.id == target.pageID }) else { return }
        session.split = target.onLeft
            ? BrowserSplit(left: id, right: target.pageID)
            : BrowserSplit(left: target.pageID, right: id)
        wake(id); wake(target.pageID)
        _ = page(for: id); _ = page(for: target.pageID)
        select(id)
    }

    func setPeekMode(_ mode: PeekMode) {
        preferences.peekMode = mode
        for store in application.map({ Array($0.stores.values) }) ?? [self] {
            store.peekMode = mode
            if mode == .off { store.dismissPeek() }
        }
    }
    func openPeek(_ url: URL) {
        dismissPeek()
        guard peekMode != .off, LinkPeekObserver.canPreview(url) else { return }
        let size = visiblePage?.webView.bounds.size ?? .zero
        peekViewport = size.width > 0 && size.height > 0 ? size : CGSize(width: 1200, height: 900)
        let page = TabPage(services: services, profileID: session.profileID)
        page.onServiceError = { [weak self] in self?.persistenceError = $0 }
        page.openPeek = { [weak self] in self?.openPeek($0) }
        page.openTab = { [weak self] in self?.newTab(url: $0.url) }
        page.isPassivePreview = true
        // A non-HTML response stays as a metadata card; never initiate a download.
        page.previewUnavailable = { }
        peekPage = page; peekURL = url
        if PeekPreview.documentType(url) == nil { page.load(url) }
    }
    func deferPeekDismissal() {
        let id = peekPage?.tabID
        let generation = UUID()
        peekDismissGeneration = generation
        // Allow the pointer to cross from the source link into the preview controls.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, self.peekPage?.tabID == id, self.peekDismissGeneration == generation, !self.peekInteracting, !self.peekSwiping else { return }
            self.dismissPeek()
        }
    }
    func dismissPeek() { peekDismissGeneration = UUID(); peekInteracting = false; peekSwiping = false; peekPage?.dispose(); peekPage = nil; peekURL = nil; peekSourceID = nil; peekLinkBounds = nil }
    func promotePeek() {
        guard let page = peekPage else { return }
        if let url = peekURL, PeekPreview.documentType(url) != nil || PeekPreview.documentType(mime: page.responseDetails?.mime) != nil {
            dismissPeek(); newTab(url: url); return
        }
        peekPage = nil; peekURL = nil
        page.isPassivePreview = false; page.previewUnavailable = nil
        session.tabs.append(BrowserTab(id: page.tabID, url: page.currentURL, title: page.pageTitle ?? "New Tab"))
        pages[page.tabID] = page
        bind(page, to: page.tabID)
        select(page.tabID)
    }
    func splitWith(_ id: UUID) {
        guard let current = session.selectedTabID, current != id, session.tabs.contains(where: { $0.id == id }) else { return }
        session.split = BrowserSplit(left: current, right: id)
        wake(id)
        _ = page(for: current); _ = page(for: id)
        save()
    }
    func replaceSplitSide(_ left: Bool, with id: UUID) {
        guard var split = session.split, session.tabs.contains(where: { $0.id == id }),
              id != (left ? split.right : split.left) else { return }
        if left { split.left = id } else { split.right = id }
        session.split = split
        wake(id); _ = page(for: id)
        session.selectedTabID = id; save()
    }
    func swapSplit() {
        guard let split = session.split else { return }
        session.split = BrowserSplit(left: split.right, right: split.left); save()
    }
    func detachSplitTab(_ id: UUID, target: TabDropTarget? = nil) {
        guard let split = session.split, id == split.left || id == split.right else { return }
        session.split = nil
        if let target { dropTab(id, target: target) }
        select(id)
    }
    func endSplit() { session.split = nil; save() }
}
