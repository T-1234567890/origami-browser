import Foundation
import CoreGraphics
import Testing
@testable import Origami

@MainActor struct PeekLayoutTests {
    @Test func contentFramePreservesRatioBelowHeader() {
        for viewport in [CGSize(width: 1440, height: 900), CGSize(width: 900, height: 1440)] {
            let card = PeekLayout.cardSize(viewport: viewport)
            let available = CGSize(width: card.width - PeekLayout.contentInset * 2,
                                   height: card.height - PeekLayout.headerHeight - PeekLayout.contentInset * 2)
            let size = PeekLayout.previewSize(viewport: viewport, available: available)
            #expect(abs(size.width / size.height - viewport.width / viewport.height) < 0.001)
            let original = PeekLayout.size(viewport: viewport)
            #expect(card.width == original.width)
            #expect(card.height == original.height + PeekLayout.headerHeight)
            #expect(size.width <= available.width + 0.001 && size.height <= available.height + 0.001)
            #expect(size.width < original.width && size.height < original.height)
            #expect(size.width / original.width > 0.9)

        }
        #expect(PeekLayout.previewSize(viewport: .zero, available: CGSize(width: 100, height: 100)) == .zero)
    }
    @Test func insideSwipeAndMomentumDoNotDismissPeek() {
        var interaction = PeekScrollInteraction()
        let dismiss1 = interaction.shouldDismiss(inside: true, began: true, ended: false, momentum: false)
        #expect(!dismiss1)
        #expect(interaction.protectsHover)
        let dismiss2 = interaction.shouldDismiss(inside: false, began: false, ended: false, momentum: false)
        #expect(!dismiss2)
        let dismiss3 = interaction.shouldDismiss(inside: false, began: false, ended: true, momentum: false)
        #expect(!dismiss3)
        #expect(!interaction.protectsHover)
        let dismiss4 = interaction.shouldDismiss(inside: false, began: false, ended: false, momentum: true)
        #expect(!dismiss4)
        let dismiss5 = interaction.shouldDismiss(inside: false, began: true, ended: false, momentum: false)
        #expect(dismiss5)
    }
    @Test func viewportRatioIsPreservedWithoutFullDocumentHeight() {
        let size = PeekLayout.size(viewport: CGSize(width: 1440, height: 900))
        #expect(abs(size.width / size.height - 1.6) < 0.001)
        #expect(size.width <= 280 && size.height <= 200)
    }
    @Test func placementAvoidsWrappedAndBottomLinks() throws {
        let container = CGSize(width: 900, height: 600)
        for link in [CGRect(x: 30, y: 40, width: 800, height: 75), CGRect(x: 30, y: 530, width: 800, height: 50), CGRect(x: 820, y: 280, width: 65, height: 30)] {
            let frame = try #require(PeekLayout.frame(viewport: CGSize(width: 1200, height: 800), link: link, container: container))
            #expect(!frame.intersects(link.insetBy(dx: -12, dy: -12)))
            #expect(CGRect(origin: .zero, size: container).insetBy(dx: 12, dy: 12).contains(frame))
        }
        #expect(PeekLayout.frame(viewport: CGSize(width: 1200, height: 800), link: CGRect(x: 0, y: 0, width: 900, height: 600), container: container) == nil)
    }
    @Test func movingToAnotherLinkReplacesPreviewWithoutAddingTabs() throws {
        let store = BrowserStore()
        defer { store.dismissPeek(); store.pages.values.forEach { $0.dispose() } }
        let count = store.session.tabs.count
        store.openPeek(URL(string: "https://first.invalid/article")!)
        let first = try #require(store.peekPage?.tabID)
        store.openPeek(URL(string: "https://second.invalid/article")!)
        #expect(store.peekPage?.tabID != first)
        #expect(store.session.tabs.count == count)
    }
}
