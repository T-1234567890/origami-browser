import AppKit
import Testing
@testable import Origami

@MainActor struct WallpaperImageTests {
    @Test func replacingCancellingAndInvalidImagesPreserveState() async throws {
        let suite = "WallpaperImageTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = Personalization(defaults: defaults)
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: file) }
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4096, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: file)
        for _ in 0..<5 { try await settings.replaceWallpaper(from: file) }
        let saved = try #require(settings.wallpaper)
        let image = try #require(NSBitmapImageRep(data: saved))
        #expect(image.pixelsWide <= 1600)
        try await settings.replaceWallpaper(from: nil)
        #expect(settings.wallpaper == saved)
        try Data("invalid image".utf8).write(to: file)
        do { try await settings.replaceWallpaper(from: file); Issue.record("Invalid image accepted") } catch {}
        #expect(settings.wallpaper == saved)
        try Data(repeating: 0, count: 50_000_001).write(to: file)
        do { try await settings.replaceWallpaper(from: file); Issue.record("Oversized image accepted") } catch {}
        #expect(settings.wallpaper == saved)
        settings.wallpaper = nil
        #expect(settings.wallpaper == nil)
        #expect(Personalization(defaults: defaults).wallpaper == nil)
    }
}
