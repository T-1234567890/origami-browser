import AppKit
import Testing
@testable import Origami

@MainActor
struct MediaArtworkTests {
    @Test func reuseDeduplicationAndCancelledWaiter() async {
        var calls = 0
        let image = NSImage(size: CGSize(width: 320, height: 180))
        let service = MediaArtworkService { _ in
            calls += 1
            try? await Task.sleep(for: .milliseconds(40))
            return image
        }
        let url = URL(string: "https://example.com/art.png")!
        let first = Task { await service.load(url) }
        await Task.yield()
        let second = Task { await service.load(url) }
        await Task.yield()
        first.cancel()
        #expect(await second.value === image)
        _ = await first.value
        #expect(await service.load(url) === image)
        #expect(calls == 1)
    }
    @Test func failureIsCachedBrieflyAndFallsBack() async {
        var calls = 0
        let service = MediaArtworkService { _ in calls += 1; return nil }
        let url = URL(string: "https://example.com/missing.png")!
        #expect(await service.load(url) == nil)
        #expect(await service.load(url) == nil)
        #expect(calls == 1)
        #expect(MediaImagePresentation.phase(hasArtworkURL: true, hasImage: false, failed: false) == .loading)
        #expect(MediaImagePresentation.phase(hasArtworkURL: true, hasImage: false, failed: true) == .fallback)
        #expect(MediaImagePresentation.phase(hasArtworkURL: false, hasImage: false, failed: false) == .fallback)
        #expect(MediaImagePresentation.phase(hasArtworkURL: true, hasImage: true, failed: false) == .artwork)
    }
    @Test func aspectRatioAndLowResolutionFallback() throws {
        #expect(MediaImagePresentation.fitted(CGSize(width: 100, height: 100)) == CGSize(width: 64, height: 64))
        let wide = MediaImagePresentation.fitted(CGSize(width: 1920, height: 1080))
        #expect(wide.width == 112 && wide.height == 63)
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let image = NSImage(size: CGSize(width: 16, height: 16)); image.addRepresentation(rep)
        #expect(MediaImagePresentation.faviconSize(image, scale: 2).width <= 16)
    }
}
