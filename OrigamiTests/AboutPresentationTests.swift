import Foundation
import AppKit
import Testing
@testable import Origami

@MainActor struct AboutPresentationTests {
    @Test func bundledCreditsAreReadableWithoutSourceCheckout() throws {
        for document in CreditDocument.all {
            let content = try #require(document.text())
            #expect(!content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
    @Test func aboutIconIsBundled() throws {
        let icon = try #require(NSImage(named: "AboutIcon"))
        #expect(icon.size.width > 0 && icon.size.height > 0)
    }
    @Test func settingsLabelsReflectActualScope() {
        var profile = BrowserProfile(id: UUID(), name: "Work", createdAt: Date(), websiteStoreID: UUID())
        #expect(SettingsScope.label(category: "Appearance", profile: profile) == "Synchronized with default profile")
        profile.sharing.appearance = false
        profile.sharing.layout = false
        #expect(SettingsScope.label(category: "Appearance", profile: profile) == "Work")
        #expect(SettingsScope.label(category: "Tabs", profile: profile) == "Work")
        for category in ["General", "Search", "AI", "Downloads", "Privacy"] {
            #expect(SettingsScope.label(category: category, profile: profile) == "Synchronized with default profile")
        }
        let personal = BrowserProfile(id: BrowserProfile.defaultID, name: "Personal", createdAt: Date(), websiteStoreID: nil)
        #expect(SettingsScope.label(category: "Appearance", profile: personal) == nil)
    }
    @Test func creditsDestinationOpensWithoutReplacingCurrentTab() {
        let application = BrowserApplicationContext(isolated: true)
        let store = application.resolve(nil)
        defer { for id in Array(application.stores.keys) { application.close(id) } }
        let original = store.session.selectedTabID
        let count = store.session.tabs.count
        let credits = store.newTab(url: InternalPage.credits.url)
        #expect(credits != original)
        #expect(store.session.tabs.count == count + 1)
        #expect(InternalRoute.page(for: InternalPage.credits.url) == .credits)
        #expect(InternalPage.credits.title == "Credits & Licenses")
    }
    @Test func aboutLinksUseCanonicalDestinations() {
        #expect(OrigamiLinks.website.absoluteString == "https://origami.1234567890.dev/")
        #expect(OrigamiLinks.terms.path == "/terms")
        #expect(OrigamiLinks.privacy.path == "/privacy")
        #expect(OrigamiLinks.repository.absoluteString == "https://github.com/T-1234567890/origami-browser")
    }
}
