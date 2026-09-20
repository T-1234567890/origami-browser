import Testing
import WebKit
@testable import Origami

@MainActor struct BlockingTests {
    // Synthetic filter data authored for these tests, not copied from a subscription.
    static let fixture = "[Adblock Plus 2.0]\n||ads.example.invalid^$third-party\n@@||ads.example.invalid/allowed.js\n"
    @Test func converterKeepsExceptionsLastAndSkipsUnsupportedBlocks() throws {
        let result = try FilterConverter.convert([Self.fixture + "||unsafe.example.invalid^$redirect=noop\nexample.invalid##.advert\n", "[Adblock Plus 2.0]\n||tracking.example.invalid^$script\n"])
        #expect(result.rules.count == 3)
        #expect(result.skipped == 2)
        #expect(result.rules.last?.action.type == "ignore-previous-rules")
        #expect(result.rules.first?.trigger.loadType == ["third-party"])
        #expect(result.rules[1].trigger.resourceType == ["script"])
    }
    @Test func unsupportedExceptionsAreConservativeAndBadfilterDisablesRule() throws {
        let result = try FilterConverter.convert([Self.fixture + "||disabled.example.invalid^\n||disabled.example.invalid^$badfilter\n@@||allowed.example.invalid^$document\n", "[Adblock Plus 2.0]\n"])
        #expect(!result.rules.contains { $0.trigger.urlFilter.contains("disabled") })
        #expect(result.rules.last?.action.type == "ignore-previous-rules")
        #expect(FilterConverter.parse("||example.invalid^$domain=site.invalid")?.trigger.ifDomain == ["*site.invalid"])
        #expect(FilterConverter.parse("||example.invalid^$domain=site.invalid|~child.site.invalid") == nil)
        #expect(FilterConverter.parse("/untrusted(regex)/") == nil)
        #expect(FilterConverter.parse("/ad-path/*")?.action.type == "block")
    }
    @Test func invalidInputsAndHostBoundaries() throws {
        #expect(throws: FilterConverter.Failure.self) { try FilterConverter.convert(["<html>Error</html>", Self.fixture]) }
        #expect(!FilterConverter.validHost("host.invalid/path"))
        let pattern = BlockingRule.exception(host: "site.invalid").trigger.ifTopURL![0]
        #expect("https://site.invalid/path".range(of: pattern, options: .regularExpression) != nil)
        #expect("https://site.invalid.evil/path".range(of: pattern, options: .regularExpression) == nil)
        #expect("https://child.site.invalid/path".range(of: pattern, options: .regularExpression) == nil)
    }
    @Test func customContentRulesStartEmptyAndValidateEdits() async throws {
        let preferences = BrowserPreferences()
        let service = BlockingService(preferences: preferences)
        await service.prepare()
        #expect(service.contentDomains.isEmpty)
        #expect(UserContentRules.rules(domains: []).isEmpty)
        try service.saveContentDomains("Example.invalid\nexample.invalid")
        await service.prepare()
        #expect(service.contentDomains == ["example.invalid"])
        #expect(throws: FilterDownloads.Failure.self) { try service.saveContentDomains("https://wrong.invalid/path") }
        #expect(preferences.contentBlockingDomains == ["example.invalid"])
        try service.saveContentDomains("")
        await service.prepare()
        #expect(service.contentDomains.isEmpty)
    }
    @Test func excludedSitesRemainIndependentAndDoNotEnableBlocking() async throws {
        let preferences = BrowserPreferences()
        let service = BlockingService(preferences: preferences)
        await service.prepare()
        try service.saveContentExcludedSites("Site.invalid\nsite.invalid\nother.invalid")
        await service.prepare()
        #expect(!service.contentEnabled)
        #expect(service.contentExcludedSites == ["other.invalid", "site.invalid"])
        #expect(service.allowsSite("site.invalid", kind: .content))
        #expect(!service.allowsSite("site.invalid", kind: .ads))
        #expect(throws: FilterDownloads.Failure.self) { try service.saveContentExcludedSites("https://invalid.test/path") }
        #expect(service.contentExcludedSites.count == 2)
        service.setAllowed(false, host: "site.invalid", kind: .content)
        await service.prepare()
        #expect(service.contentExcludedSites == ["other.invalid"])
        service.setAllowed(true, host: "popover.invalid", kind: .content)
        await service.prepare()
        #expect(service.contentExcludedSites == ["other.invalid", "popover.invalid"])
        #expect(!service.allowsSite("popover.invalid", kind: .ads))
        try service.saveContentExcludedSites("")
        await service.prepare()
        #expect(!service.allowsSite("popover.invalid", kind: .content))
        #expect(preferences.blockingExceptions(.content).isEmpty)
        #expect(!preferences.contentBlocking)
    }
    @Test func importingDomainsMergesAndRejectsInvalidFilesAtomically() async throws {
        let service = BlockingService(preferences: BrowserPreferences())
        await service.prepare()
        try service.saveContentDomains("existing.invalid")
        try service.importContentRules(Data("\u{FEFF}New.invalid\r\nexisting.invalid\r\n".utf8))
        #expect(service.contentDomains == ["existing.invalid", "new.invalid"])
        #expect(!service.contentEnabled)
        #expect(throws: FilterDownloads.Failure.self) { try service.importContentRules(Data("valid.invalid\nhttps://invalid/path".utf8)) }
        #expect(throws: FilterDownloads.Failure.self) { try service.importContentRules(Data([0xff, 0xfe])) }
        #expect(throws: FilterDownloads.Failure.self) { try service.importContentRules(Data(repeating: 65, count: 1_048_577)) }
        #expect(service.contentDomains == ["existing.invalid", "new.invalid"])
        await service.prepare()
    }
    @Test func preferencesAreIndependentAndPersist() throws {
        let name = "Origami.BlockingTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
        let p = BrowserPreferences(defaults: defaults)
        #expect(!p.adBlocking && !p.contentBlocking)
        p.contentBlocking = true; p.setBlockingExceptions(["site.invalid"], kind: .content)
        let restored = BrowserPreferences(defaults: defaults)
        #expect(restored.contentBlocking && !restored.adBlocking)
        #expect(restored.blockingExceptions(.ads).isEmpty)
        #expect(restored.blockingExceptions(.content) == ["site.invalid"])
    }
    @Test func nativeCompilationWorksForOwnedAndConvertedRules() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let compiler = try #require(WKContentRuleListStore(url: folder))
        // Every supported filter resource type must compile in real WebKit, not
        // merely round-trip through JSON. EasyList's stylesheet spelling differs.
        let typedRules = ["script", "image", "stylesheet", "font", "media", "xmlhttprequest"]
            .map { "||typed.example.invalid^$" + $0 }.joined(separator: "\n")
        let conversion = try FilterConverter.convert([Self.fixture + typedRules, "[Adblock Plus 2.0]\n||track.example.invalid^$domain=site.invalid\n"])
        #expect(conversion.rules.contains { $0.trigger.resourceType == ["style-sheet"] })
        for (i, rules) in [UserContentRules.rules(domains: ["example.invalid"]), conversion.rules + [.exception(host: "site.invalid")]].enumerated() {
            let json = String(decoding: try JSONEncoder().encode(rules), as: UTF8.self)
            #expect(try await compiler.compileContentRuleList(forIdentifier: "test-\(i)", encodedContentRuleList: json) != nil)
        }
    }
    @Test func optInDownloadsRefreshFailureAndRestartUseLastGoodSnapshot() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = MockFilters()
        let prefs = BrowserPreferences()
        let service = BlockingService(preferences: prefs, directory: folder, downloader: { try await source.load($0) })
        await service.prepare()
        #expect(await source.calls == 0)
        service.contentEnabled = true; await service.prepare()
        #expect(await source.calls == 0)
        service.adsEnabled = true; await service.prepare(); await service.waitForUpdate()
        #expect(await source.calls == 2)
        let snapshotURL = folder.appending(path: "filters.json")
        let original = try Data(contentsOf: snapshotURL)
        await source.fail()
        service.refreshIfNeeded(force: true); await service.waitForUpdate()
        #expect(service.status.contains("Keeping the last working"))
        #expect(try Data(contentsOf: snapshotURL) == original)
        service.setAllowed(true, host: "site.invalid", kind: .ads); await service.prepare()
        #expect(service.allowsSite("site.invalid", kind: .ads))
        #expect(!service.allowsSite("site.invalid", kind: .content))
        service.adsEnabled = false; await service.prepare()
        #expect(service.contentEnabled)
        prefs.adBlocking = true
        let restored = BlockingService(preferences: prefs, directory: folder, downloader: { _ in throw URLError(.notConnectedToInternet) })
        await restored.prepare()
        #expect(restored.status.hasPrefix("Updated"))
        #expect(restored.allowsSite("site.invalid", kind: .ads))
    }
}
private actor MockFilters {
    var calls = 0
    var failing = false
    func fail() { failing = true }
    func load(_ url: URL) throws -> String {
        calls += 1
        if failing { throw URLError(.notConnectedToInternet) }
        return "[Adblock Plus 2.0]\n||ads.example.invalid^$script\n"
    }
}
