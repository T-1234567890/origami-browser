import Foundation
import Testing
@testable import Origami

struct ReleaseInfrastructureTests {
    @Test(arguments: [("v1.0.0", "Origami 1.0.0", ReleaseStage.stable), ("v1.0.0-beta.1", "Origami 1.0.0 Beta 1", .beta), ("v1.2.3", "Origami 1.2.3", .stable), ("v2.3.4-beta.12", "Origami 2.3.4 Beta 12", .beta)])
    func validTags(tag: String, display: String, stage: ReleaseStage) throws {
        let identity = try ReleaseIdentity(tag: tag, buildNumber: 101)
        #expect(identity.displayVersion == display)
        #expect(identity.stage == stage)
        #expect(identity.buildNumber == 101)
        #expect(identity.channel == (stage == .stable ? nil : "beta"))
    }
    @Test(arguments: ["1.0.0", "v1", "v1.0", "v1.0.0-beta", "v1.0.0-beta.0", "v1.0.0-random.1", "v01.0.0", "v1.0.0-rc.1", "v1.0.0-alpha.1", "v1.00.0", "v1.0.00", "v1.0.0-beta.01", "v1.0.0-beta.-1", "v1.0.0\n", "v1.0.0+build", "v1.0.0-beta.99999999999999999999999999"])
    func invalidTags(_ tag: String) { #expect(throws: (any Error).self) { try ReleaseIdentity(tag: tag, buildNumber: 1) } }
    @Test func nonPositiveBuildsRejected() { for build in [0, -1] { #expect(throws: (any Error).self) { try ReleaseIdentity(tag: "v1.0.0", buildNumber: build) } } }
    @Test func channelsAndPersistenceIndependentFromIdentity() throws {
        let suite = "Origami.ReleaseTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = UpdatePreferences(defaults: defaults)
        let installed = try ReleaseIdentity(tag: "v1.0.0", buildNumber: 103)
        #expect(preferences.channel == .stable)
        #expect(UpdateChannel.stable.sparkleChannels.isEmpty)
        #expect(!UpdateChannel.stable.accepts(.beta))
        preferences.channel = .beta
        #expect(UpdatePreferences(defaults: defaults).channel == .beta)
        for stage in ReleaseStage.allCases { #expect(UpdateChannel.beta.accepts(stage)) }
        #expect(UpdateChannel.beta.sparkleChannels == ["beta"])
        #expect(installed.stage == .stable); #expect(installed.displayVersion == "Origami 1.0.0")
        preferences.channel = .stable
        #expect(installed.buildNumber == 103)
    }
    @Test func bundleMetadataValidation() {
        var info: [String: Any] = ["OrigamiReleaseTag": "v1.0.0-beta.1", "OrigamiReleaseStage": "beta", "OrigamiPrereleaseNumber": "1", "CFBundleVersion": "102", "CFBundleShortVersionString": "1.0.0"]
        #expect(ReleaseIdentity.from(info: info)?.displayVersion == "Origami 1.0.0 Beta 1")
        info["OrigamiReleaseStage"] = "stable"
        #expect(ReleaseIdentity.from(info: info) == nil)
        #expect(ReleaseIdentity.from(info: [:]) == nil)
    }
    @Test func invalidConfigurationFailsClosed() {
        let publicKey = Data(repeating: 0, count: 32).base64EncodedString() // Public, non-secret fixture bytes.
        for feed in ["", "$(ORIGAMI_FEED_URL)", "http://example.invalid/feed", "file:///feed", "https://user:password@example.invalid/feed", "https://example.invalid/feed?token=fixture"] {
            #expect(UpdateConfiguration(info: ["SUFeedURL": feed, "SUPublicEDKey": publicKey]) == nil)
        }
        #expect(UpdateConfiguration(info: ["SUFeedURL": "https://example.org/appcast.xml", "SUPublicEDKey": ""]) == nil)
        #expect(UpdateConfiguration(info: ["SUFeedURL": "https://example.org/appcast.xml", "SUPublicEDKey": publicKey]) != nil)
    }
}
