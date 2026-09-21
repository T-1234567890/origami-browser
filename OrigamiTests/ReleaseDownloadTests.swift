import Testing
import WebKit
@testable import Origami

@MainActor struct ReleaseDownloadTests {
    @Test(.timeLimit(.minutes(1))) func detachedWebViewDownloadsCompleteAndPersist() async throws {
        let db = try DatabaseManager()
        _ = try ProfileRepository(db).ensureDefault()
        let repository = DownloadRepository(db)
        let service = DownloadService(repository: repository)
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        service.destinationSelector = { name in folder.appending(path: UUID().uuidString + name) }
        let url = URL(string: "data:application/octet-stream;base64,SGVsbG8=")!
        for _ in 0..<2 {
            let web = WKWebView()
            web.loadHTMLString("<title>Download fixture</title>", baseURL: URL(string: "https://example.invalid"))
            for _ in 0..<100 {
                if web.title == "Download fixture" && !web.isLoading { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let download = await web.startDownload(using: URLRequest(url: url))
            service.accept(download, profileID: BrowserProfile.defaultID, tabID: UUID(), sourceWebView: web)
            web.stopLoading() // TabPage disposal stops navigation when the tab closes.
        }
        for _ in 0..<300 {
            let records = try repository.list(profileID: BrowserProfile.defaultID)
            if records.count == 2 && records.allSatisfy({ [.completed, .failed, .cancelled].contains($0.state) }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let records = try repository.list(profileID: BrowserProfile.defaultID)
        #expect(records.count == 2)
        #expect(records.allSatisfy { $0.state == .completed })
        #expect(Set(records.compactMap(\.destination)).count == 2)
        for record in records {
            #expect(record.received == 5)
            let path = try #require(record.destination)
            #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("Hello".utf8))
        }
        #expect(service.runningProfiles.isEmpty)
    }
    @Test(.timeLimit(.minutes(1))) func cancellingDestinationIsTerminalAndPreservesExistingFiles() async throws {
        let db = try DatabaseManager()
        _ = try ProfileRepository(db).ensureDefault()
        let repo = DownloadRepository(db)
        let service = DownloadService(repository: repo)
        service.destinationSelector = { _ in nil }
        let web = WKWebView()
        web.loadHTMLString("<title>Cancel fixture</title>", baseURL: URL(string: "https://example.invalid"))
        for _ in 0..<100 {
            if web.title == "Cancel fixture" && !web.isLoading { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let download = await web.startDownload(using: URLRequest(url: URL(string: "data:application/octet-stream;base64,SGVsbG8=")!))
        service.accept(download, profileID: BrowserProfile.defaultID, tabID: UUID(), sourceWebView: web)
        for _ in 0..<100 {
            if try repo.list(profileID: BrowserProfile.defaultID).first?.state == .cancelled { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try repo.list(profileID: BrowserProfile.defaultID).first?.state == .cancelled)
        #expect(service.runningProfiles.isEmpty)
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data("keep".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(throws: (any Error).self) { try service.panel(NSObject(), validate: file) }
        #expect(try Data(contentsOf: file) == Data("keep".utf8))
    }

    @Test func historyRecoveryAndPrivateIsolation() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "downloads.sqlite")
        do {
            let db = try DatabaseManager(fileURL: url)
            _ = try ProfileRepository(db).ensureDefault()
            let repo = DownloadRepository(db)
            var completed = DownloadRecord(profileID: BrowserProfile.defaultID, tabID: nil, url: "https://example.invalid/file?secret=fixture")
            completed.state = .completed
            try repo.save(completed)
            var pending = DownloadRecord(profileID: BrowserProfile.defaultID, tabID: nil, url: "https://example.invalid/pending")
            pending.state = .running
            try repo.save(pending)
        }
        let reopened = try DatabaseManager(fileURL: url)
        let repo = DownloadRepository(reopened)
        try repo.recoverInterrupted()
        let records = try repo.list(profileID: BrowserProfile.defaultID)
        #expect(Set(records.map { $0.state.rawValue }) == ["completed", "interrupted"])
        #expect(records.allSatisfy { !$0.url.contains("?") })
        let privateDB = try DatabaseManager()
        _ = try ProfileRepository(privateDB).ensureDefault()
        let privateRepo = DownloadRepository(privateDB)
        try privateRepo.save(DownloadRecord(profileID: BrowserProfile.defaultID, tabID: nil, url: "https://private.invalid/file"))
        #expect(try repo.list(profileID: BrowserProfile.defaultID).count == 2)
        #expect(try DownloadRepository(DatabaseManager()).list(profileID: BrowserProfile.defaultID).isEmpty)
    }

    @Test func filenameAndReservations() {
        #expect(DownloadService.filename("../file", mime: "application/pdf") == "file.pdf")
        #expect(DownloadService.filename("..", mime: nil) == "Download")
        let folder = URL(fileURLWithPath: "/synthetic")
        #expect(DownloadService.availableDestination(directory: folder, filename: "a.zip", reserved: ["/synthetic/a.zip"]).lastPathComponent == "a (1).zip")
    }
}
