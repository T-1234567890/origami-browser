import Testing
import WebKit
@testable import Origami

@MainActor struct PageZoomTests {
    @Test func boundedStepsAndAddressSymbols() {
        #expect(PageZoom.step(from: 1, increasing: true) == 1.1)
        #expect(PageZoom.step(from: 1, increasing: false) == 0.9)
        #expect(PageZoom.step(from: 5, increasing: true) == 5)
        #expect(PageZoom.step(from: 0.25, increasing: false) == 0.25)
        #expect(PageZoom.symbol(for: 1) == "magnifyingglass")
        #expect(PageZoom.symbol(for: 1.25) == "plus.magnifyingglass")
        #expect(PageZoom.symbol(for: 0.8) == "minus.magnifyingglass")
    }

    @Test func zoomChangesWebKitAndStaysPerTab() {
        let page = TabPage(), other = TabPage()
        defer { page.dispose(); other.dispose() }
        page.zoom(increasing: true)
        #expect(page.webView.pageZoom == 1.1)
        #expect(other.zoomLevel == 1 && other.webView.pageZoom == 1)
        page.resetZoom()
        #expect(page.zoomLevel == 1 && page.webView.pageZoom == 1)
        page.zoom(increasing: false)
        #expect(page.webView.pageZoom == 0.9)
        page.readerVisible = true
        page.zoom(increasing: true)
        #expect(page.zoomLevel == 0.9)
    }

    @Test func transientPlaybackMetadataKeepsOnlySameTrackArtwork() {
        var previous = TabMediaState(snapshot: ["id":"track", "phase":"playing", "title":"Song", "source":"example.com", "artwork":"https://example.com/art.png"])
        var paused = TabMediaState(snapshot: ["id":"track", "phase":"paused", "title":"Song", "source":"example.com"])
        paused.preserveArtwork(from: previous)
        #expect(paused.artworkURL == previous.artworkURL)
        var next = TabMediaState(snapshot: ["id":"track", "phase":"playing", "title":"Different Song", "source":"example.com"])
        next.preserveArtwork(from: previous)
        #expect(next.artworkURL == nil)
        previous = TabMediaState()
        next.preserveArtwork(from: previous)
        #expect(next.artworkURL == nil)
    }
}
