import Testing
import Foundation
@testable import Origami

@MainActor struct CitationPresentationTests {
    @Test func backgroundFormattingRetainsMetadata() async {
        let citation = PageCitation(title: "A useful source", author: "Smith, Jane", published: "2024-01-01", url: "https://example.com/source")
        let result = await CitationFormattingWorker.shared.format(citation, style: "APA")
        #expect(result.contains("Smith") && result.contains("2024") && result.contains("https://example.com/source"))
    }
    @Test func gradientRetainsMainAccentAndCombinedFillPreference() throws {
        let name = "Origami.GradientTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = Personalization(defaults: defaults)
        #expect(settings.hex == "55D4B3" && !settings.gradientEnabled && !settings.frameFill)
        settings.hex = "D65F78"; settings.gradientHex = "84A9F5"; settings.gradientEnabled = true
        settings.frameFill = true
        let restored = Personalization(defaults: defaults)
        #expect(restored.hex == "D65F78" && restored.gradientHex == "84A9F5" && restored.gradientEnabled)
        #expect(restored.frameFill)
        defaults.set(true, forKey: "appearance.sidebarTint")
        restored.frameFill = false
        let migrated = Personalization(defaults: defaults)
        #expect(migrated.frameFill)
        #expect(defaults.object(forKey: "appearance.sidebarTint") == nil)
        migrated.frameFill = false
        #expect(!Personalization(defaults: defaults).frameFill)
    }
}
