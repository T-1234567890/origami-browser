import Testing
import Foundation
@testable import Origami

@MainActor struct MigrationDiscoveryTests {
    @Test func discoveryUsesInstalledAppsWithoutReadingBrowserContents() {
        let home = URL(fileURLWithPath: "/synthetic-home")
        let sources = MigrationDiscovery.sources(home: home, application: { id in
            id == MigrationBrowser.chrome.bundleID ? URL(fileURLWithPath: "/synthetic-apps/Chrome.app") : nil
        })
        #expect(sources.map(\.browser) == [.chrome])
        #expect(sources.first?.roots.first == home.appending(path: MigrationBrowser.chrome.dataLocations[0]))
    }
    @Test func omitsBrowsersWithoutAnInstalledApplication() {
        let sources = MigrationDiscovery.sources(home: URL(fileURLWithPath: "/synthetic-home"), application: { _ in nil })
        #expect(sources.isEmpty)
        #expect(Set(MigrationBrowser.allCases.map(\.bundleID)).count == 10)
    }
    @Test func onboardingImportSavesSeparateProfileWithoutOpeningAnotherWindow() throws {
        let app = BrowserApplicationContext(isolated: true)
        defer { for id in Array(app.stores.keys) { app.close(id) } }
        let store = try #require(app.stores[app.initialID])
        let original = store.session.profileID
        var opened = 0; app.openWindow = { _ in opened += 1 }
        let imported = try store.importBrowserProfile(MigrationProfile(name: "Imported", bookmarks: [
            .init(title: "Fixture", url: URL(string: "https://example.invalid/"))
        ]), selection: .init(), replace: false, openImported: false)
        #expect(opened == 0 && app.stores.count == 1)
        #expect(store.session.profileID == original && imported.profileID != original)
        let services = try #require(app.services)
        #expect(try services.profiles.list().contains { $0.id == imported.profileID })
        #expect(try services.bookmarks.list(profileID: imported.profileID).count == 1)
        _ = app.openImportedSession(imported)
        #expect(opened == 1 && app.stores.count == 2)
    }
    @Test func changingBrowserResetsReviewAndReplacement() {
        let flow = MigrationFlow()
        flow.replace = true; flow.completed = true; flow.needsAccess = true; flow.busy = true
        flow.profiles = [.init(name: "Fixture", bookmarks: [])]
        flow.selected = flow.profiles.first?.id
        flow.reset()
        #expect(!flow.replace && !flow.completed && !flow.needsAccess && !flow.busy)
        #expect(flow.profiles.isEmpty && flow.selected == nil && !flow.canImport)
    }
}

extension MigrationDiscoveryTests {
    @Test func installedBrowserKeepsAllCandidateDataLocations() {
        let home = URL(fileURLWithPath: "/synthetic-home")
        let sources = MigrationDiscovery.sources(home: home, application: {
            $0 == MigrationBrowser.safari.bundleID ? URL(fileURLWithPath: "/synthetic/Safari.app") : nil
        })
        let safari = sources.first { $0.browser == .safari }
        #expect(safari?.roots.count == 2)
        #expect(safari?.roots.first == home.appending(path: "Library/Safari"))
    }
    @Test func permissionFailureSurvivesMissingAlternateAndTargetsCorrectFolder() throws {
        let first = URL(fileURLWithPath: "/synthetic/primary"), second = URL(fileURLWithPath: "/synthetic/alternate")
        do {
            _ = try MigrationAccess.readRoots([first, second]) { root in
                if root == first { throw NSError(domain: NSPOSIXErrorDomain, code: 1) }
                throw MigrationFailure.unsupported
            }
            Issue.record("Expected an access request")
        } catch let error as MigrationAccessRequired { #expect(error.root == first) }
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: 13)])
        #expect(MigrationAccess.denied(wrapped))
        #expect(!MigrationAccess.denied(MigrationFailure.unsupported))
    }
    @Test func readableAlternateStillSucceedsAfterAccessDenial() throws {
        let first = URL(fileURLWithPath: "/synthetic/primary"), second = URL(fileURLWithPath: "/synthetic/alternate")
        let result = try MigrationAccess.readRoots([first, second]) { root in
            if root == first { throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError) }
            return [.init(name: "Fixture", bookmarks: [])]
        }
        #expect(result.first?.name == "Fixture")
    }
}
