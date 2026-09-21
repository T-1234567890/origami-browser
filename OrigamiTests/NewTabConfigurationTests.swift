import AppKit
import Foundation
import Testing
@testable import Origami

@MainActor struct NewTabConfigurationTests {
    @Test func aiSettingsSelectExistingSettingsTab() throws {
        let store = BrowserStore()
        defer { store.pages.values.forEach { $0.dispose() } }
        store.openInternal(.settings)
        let settings = try #require(store.session.selectedTabID)
        store.newTab()
        let count = store.session.tabs.count
        store.openAISettings()
        #expect(store.session.selectedTabID == settings)
        #expect(store.settingsCategory == "AI")
        #expect(store.session.tabs.count == count)
        store.openInternal(.settings)
        #expect(store.session.tabs.count == count)
    }
    @Test func svgTitleCanRenderAndPersist() async throws {
        let data = Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="120" height="40" viewBox="0 0 120 40"><rect width="120" height="40" fill="#55D4B3"/></svg>"##.utf8)
        #expect(NSImage(data: data) != nil)
        let name = "Origami.NewTabTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = Personalization(defaults: defaults)
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".svg")
        defer { try? FileManager.default.removeItem(at: file) }
        try data.write(to: file)
        try await settings.replaceTitleImage(from: file)
        let saved = try #require(settings.titleImage)
        #expect(NSBitmapImageRep(data: saved) != nil)
        #expect(defaults.data(forKey: "appearance.titleImage") == saved)
        let restored = try #require(Personalization(defaults: defaults).titleImage)
        let restoredImage = try #require(NSBitmapImageRep(data: restored))
        #expect(restoredImage.pixelsWide == 120 && restoredImage.pixelsHigh == 40)
        settings.resetTitleImage()
        #expect(Personalization(defaults: defaults).titleImage == nil)
    }
}
