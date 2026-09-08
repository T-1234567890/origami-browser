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
    @Test func svgTitleCanRenderAndPersist() throws {
        let data = Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="120" height="40" viewBox="0 0 120 40"><rect width="120" height="40" fill="#55D4B3"/></svg>"##.utf8)
        #expect(NSImage(data: data) != nil)
        let name = "Origami.NewTabTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = Personalization(defaults: defaults)
        settings.titleImage = data
        #expect(Personalization(defaults: defaults).titleImage == data)
        settings.titleImage = nil
        #expect(Personalization(defaults: defaults).titleImage == nil)
    }
}
