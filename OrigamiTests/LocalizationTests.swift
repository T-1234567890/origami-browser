import Foundation
import Observation
import Testing
@testable import Origami

struct LocalizationTests {
    @Test func resolvesOnlySupportedLanguages() {
        #expect(AppLanguage.resolve(.system, preferred: ["fr-FR", "zh-Hans-CN", "en-US"]) == .simplifiedChinese)
        #expect(AppLanguage.resolve(.system, preferred: ["en-GB", "zh-Hans"]) == .english)
        #expect(AppLanguage.resolve(.system, preferred: ["zh_CN"]) == .simplifiedChinese)
        #expect(AppLanguage.resolve(.system, preferred: ["zh-Hant-TW"]) == .english)
        #expect(AppLanguage.resolve(.system, preferred: []) == .english)
        #expect(AppLanguage.resolve(.english, preferred: ["zh-Hans"]) == .english)
        #expect(AppLanguage.resolve(.simplifiedChinese, preferred: ["en-US"]) == .simplifiedChinese)
        #expect(AppLanguage.allCases.map(\.rawValue) == ["system", "en", "zh-Hans"])
    }

    @MainActor @Test func preferenceUpdatesImmediatelyAndUsesIsolatedDefaults() throws {
        let suite = "LocalizationTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = LanguageManager(defaults: defaults)
        #expect(manager.selection == .system)
        let invalidated = ObservationProbe()
        withObservationTracking {
            _ = manager.locale
        } onChange: {
            invalidated.mark()
        }
        manager.selection = .simplifiedChinese
        #expect(invalidated.changed)
        #expect(manager.locale.identifier == "zh-Hans")
        #expect(L10n.string("Settings", language: manager.resolvedLanguage) == "设置")
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["zh-Hans"])
        let reopened = LanguageManager(defaults: defaults)
        #expect(reopened.selection == .simplifiedChinese)
        reopened.selection = .system
        #expect(defaults.persistentDomain(forName: suite)?["AppleLanguages"] == nil)
        #expect(reopened.resolvedLanguage == AppLanguage.resolve(.system, preferred: L10n.systemLanguages))
    }

    @Test func displayTranslationPreservesStoredAndWebsiteTitles() {
        let website = BrowserTab(url: URL(string: "https://example.com"), title: "Settings")
        #expect(website.displayTitle == "Settings")
        let internalTab = BrowserTab(url: InternalPage.settings.url, title: "Settings")
        #expect(internalTab.displayTitle == InternalPage.settings.title)
        #expect(internalTab.title == "Settings")
        let answer = BrowserTab(url: InternalPage.newtab.url, title: "My question")
        #expect(answer.displayTitle == "My question")
    }

    @Test func bundledTranslationsAndFallback() throws {
        // The app bundle is available in Xcode Cloud's test-without-building VM.
        let appBundle = Bundle.main
        #expect(appBundle.localizations.contains("en"))
        #expect(appBundle.localizations.contains("zh-Hans"))
        #expect(L10n.string("Settings", language: .simplifiedChinese, bundle: appBundle) == "设置")
        #expect(L10n.string("Settings", language: .english, bundle: appBundle) == "Settings")
        #expect(L10n.string("Unknown test key", language: .simplifiedChinese, bundle: appBundle) == "Unknown test key")
        let template = L10n.string("Bookmarks (%lld)", language: .simplifiedChinese, bundle: appBundle)
        #expect(String(format: template, Int64(3)).contains("3"))
        #expect(InternalPage.settings.rawValue == "settings")
        #expect(InternalPage.settings.url.absoluteString == "origami://settings")
    }
}

private final class ObservationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func mark() { lock.lock(); defer { lock.unlock() }; value = true }
    var changed: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
