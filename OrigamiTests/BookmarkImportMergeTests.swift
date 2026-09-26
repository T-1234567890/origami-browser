import Foundation
import Testing
@testable import Origami

struct BookmarkImportMergeTests {
    @Test func repeatedImportMergesMatchingFolderPaths() throws {
        let db = try DatabaseManager()
        let profile = try ProfileRepository(db).ensureDefault()
        let repository = BookmarkRepository(db)
        let one = URL(string: "https://example.invalid/one")!
        let two = URL(string: "https://example.invalid/two")!
        let initial: [ImportedBookmark] = [.folder("Bookmarks", [.folder("Work", [.bookmark("One", one)])])]
        #expect(try repository.importItems(initial, profileID: profile.id) == 1)
        let ids = try repository.folders(profileID: profile.id).map(\.id)
        #expect(try repository.importItems(initial, profileID: profile.id) == 0)
        #expect(try repository.importItems([.folder("Bookmarks", [.folder("Work", [.bookmark("One", one), .bookmark("Two", two)])])], profileID: profile.id) == 1)
        #expect(try repository.folders(profileID: profile.id).map(\.id) == ids)
        #expect(try repository.list(profileID: profile.id).count == 2)
        _ = try repository.importItems([.folder("Other", [.folder("Work", [.bookmark("One", one)])])], profileID: profile.id)
        #expect(try repository.folders(profileID: profile.id).count == 4)
        #expect(try repository.list(profileID: profile.id).count == 3)
    }
    @Test func browserMigrationMergesDuplicateLists() throws {
        let db = try DatabaseManager()
        _ = try ProfileRepository(db).ensureDefault()
        let one = URL(string: "https://example.invalid/one")!
        let two = URL(string: "https://example.invalid/two")!
        let profile = MigrationProfile(name: "Imported", bookmarks: [
            .init(title: "Bookmarks", children: [.init(title: "One", url: one)]),
            .init(title: "Bookmarks", children: [.init(title: "One", url: one), .init(title: "Two", url: two)])
        ])
        let session = try MigrationWriter.apply(profile, selection: .init(), database: db)
        let repository = BookmarkRepository(db)
        #expect(try repository.folders(profileID: session.profileID).count == 1)
        #expect(try repository.list(profileID: session.profileID).count == 2)
    }
}
