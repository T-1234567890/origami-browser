import Foundation
import Testing
import WebKit
@testable import Origami

struct DefaultProfileTests {
    @Test func changingDefaultPersistsAndRedirectsSharingWithoutDeletingProfiles() throws {
        let database = try DatabaseManager()
        let profiles = ProfileRepository(database)
        let original = try profiles.ensureDefault()
        let work = try profiles.create(name: "Work")
        var sharing = ProfileSharing()
        sharing.bookmarks = true
        sharing.website = true
        let shared = try profiles.create(name: "Shared", sharing: sharing)
        try profiles.setDefault(work.id)
        let reopened = ProfileRepository(database)
        #expect(reopened.defaultID == work.id)
        #expect(try reopened.ensureDefault().id == work.id)
        #expect(try reopened.list().count == 3)
        for kind in ProfileDataKind.allCases {
            #expect(try reopened.scope(original.id, kind) == original.id)
            #expect(try reopened.scope(work.id, kind) == work.id)
        }
        #expect(try reopened.scope(shared.id, .bookmarks) == work.id)
        #expect(try reopened.scope(shared.id, .website) == work.id)
        #expect(throws: RepositoryError.self) { try reopened.delete(work.id) }
        try reopened.delete(original.id)
        #expect(try reopened.ensureDefault().id == work.id)
        #expect(try reopened.list().count == 2)
    }
    @MainActor @Test func websiteSharingUsesSelectedDefaultDataStore() throws {
        let profiles = ProfileRepository(try DatabaseManager())
        _ = try profiles.ensureDefault()
        let work = try profiles.create(name: "Work")
        var sharing = ProfileSharing(); sharing.website = true
        let shared = try profiles.create(name: "Shared", sharing: sharing)
        try profiles.setDefault(work.id)
        let service = WebsiteDataService(profiles: profiles)
        #expect(service.store(for: shared).identifier == work.websiteStoreID)
    }

    @Test func startupUsesPersistedDefaultInsteadOfLastActiveProfile() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "profiles.sqlite")
        let preferences = BrowserPreferences(defaults: nil)
        let sessions = SessionStore(fileURL: url, preferences: preferences)
        let profiles = ProfileRepository(try sessions.database)
        let work = try profiles.create(name: "Work")
        try profiles.setDefault(work.id)
        preferences.currentProfileID = BrowserProfile.defaultID
        let reopened = SessionStore(fileURL: url, preferences: preferences)
        #expect(try reopened.load().profileID == work.id)
    }

    @Test func invalidDefaultLeavesSelectionUnchanged() throws {
        let profiles = ProfileRepository(try DatabaseManager())
        let original = try profiles.ensureDefault()
        #expect(throws: RepositoryError.self) { try profiles.setDefault(UUID()) }
        #expect(profiles.defaultID == original.id)
    }
}
