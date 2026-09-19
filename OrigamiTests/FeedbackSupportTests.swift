import Foundation
import Testing
@testable import Origami

struct FeedbackSupportTests {
    @Test func betaInfoContainsOnlyAllowedFields() {
        let info: [String: Any] = [
            "OrigamiReleaseTag": "v1.0.1-beta.5", "CFBundleVersion": "123",
            "CFBundleShortVersionString": "1.0.1", "OrigamiReleaseStage": "beta",
            "OrigamiPrereleaseNumber": "5", "profileName": "PRIVATE",
            "currentURL": "https://private.example", "APIKey": "SECRET"
        ]
        #expect(SupportInfo.text(info: info, system: .init(majorVersion: 15, minorVersion: 4, patchVersion: 1), architecture: "arm64") == """
        Origami 1.0.1 Beta 5
        Build 123
        macOS 15.4.1
        Architecture: arm64
        Channel: Beta
        """)
    }
    @Test func stableAndDevelopmentChannelsAreExplicit() {
        let system = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        let info: [String: Any] = ["OrigamiReleaseTag": "v1.1.0", "CFBundleVersion": "124",
                                  "CFBundleShortVersionString": "1.1.0", "OrigamiReleaseStage": "stable",
                                  "OrigamiPrereleaseNumber": ""]
        let stable = SupportInfo.text(info: info, system: system, architecture: "x86_64")
        #expect(stable.hasPrefix("Origami 1.1.0\nBuild 124\n"))
        #expect(stable.hasSuffix("Architecture: x86_64\nChannel: Stable"))
        let development = SupportInfo.text(info: [:], system: system, architecture: "arm64")
        #expect(development.hasPrefix("Origami Unknown — Development\nBuild Unknown"))
        #expect(development.hasSuffix("Channel: Development"))
    }
    @Test func supportLinksUseRepositoryWithoutBrowserData() throws {
        for destination in SupportDestination.allCases {
            #expect(destination.url.host == "github.com")
            #expect(destination.url.path.hasPrefix("/T-1234567890/origami-browser/"))
        }
        #expect(SupportDestination.roadmap.url.path.hasSuffix("/blob/main/roadmap.md"))
        #expect(SupportDestination.security.url.path.hasSuffix("/blob/main/SECURITY.md"))
        #expect(SupportDestination.issues.url.path.hasSuffix("/issues"))
        for destination in [SupportDestination.bug, .feature] {
            #expect(destination.url.path.hasSuffix("/issues/new"))
            let components = try #require(URLComponents(url: destination.url, resolvingAgainstBaseURL: false))
            #expect(components.queryItems?.map(\.name) == ["title"])
        }
    }
}
