import Foundation
import AppKit
import CoreGraphics

extension BrowserStore {
    func openPeek(_ url: URL) {
        dismissPeek()
        guard LinkPeekObserver.canPreview(url) else { return }
        let size = visiblePage?.webView.bounds.size ?? .zero
        peekViewport = size.width > 0 && size.height > 0 ? size : CGSize(width: 1200, height: 900)
        let page = TabPage(services: services, profileID: session.profileID)
        page.onServiceError = { [weak self] in self?.persistenceError = $0 }
        page.openPeek = { [weak self] in self?.openPeek($0) }
        page.openTab = { [weak self] in self?.newTab(url: $0.url) }
        page.isPassivePreview = true
        page.previewUnavailable = { [weak self, weak page] in
            DispatchQueue.main.async { if let page, self?.peekPage === page { self?.dismissPeek() } }
        }
        peekPage = page
        page.load(url)
    }
    func dismissPeek() { peekPage?.dispose(); peekPage = nil; peekSourceID = nil; peekLinkBounds = nil }
    func promotePeek() {
        guard let page = peekPage else { return }
        peekPage = nil
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
    func endSplit() { session.split = nil; save() }
}
