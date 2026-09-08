import Foundation
import CoreServices
import Testing
@testable import Origami

struct DownloadQuarantineTests {
    @Test(arguments: ["sample.dmg", "sample.pkg", "sample.app.zip", "sample.zip", "sample.app", "sample.sh", "sample.command", "executable", "sample.pdf", "sample.mp3", "sample.mp4"])
    func allFileTypesReceiveVerifiedQuarantine(_ name: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(name)
        if name.hasSuffix(".app") { try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true) }
        else { try Data("Inert quarantine fixture. Do not execute.".utf8).write(to: file) }
        let source = URL(string: "https://downloads.example.com/\(name)?token=secret")!
        let origin = URL(string: "https://example.com/downloads#section")!
        try DownloadQuarantine.enforce(at: file, downloadURL: source, originURL: origin)
        let first = try DownloadQuarantine.properties(at: file)
        #expect(try !DownloadQuarantine.attribute("com.apple.quarantine", at: file).isEmpty)
        #expect(!(first[kLSQuarantineAgentNameKey as String] as? String ?? "").isEmpty)
        let metadata = try DownloadQuarantine.attribute("com.apple.metadata:kMDItemWhereFroms", at: file)
        let origins = try PropertyListSerialization.propertyList(from: metadata, format: nil) as? [String]
        #expect(origins == ["https://downloads.example.com/\(name)", "https://example.com/downloads"])
        try DownloadQuarantine.enforce(at: file, downloadURL: source, originURL: origin)
        #expect(try DownloadQuarantine.properties(at: file)[kLSQuarantineTimeStampKey as String] as? Date == first[kLSQuarantineTimeStampKey as String] as? Date)
    }
    @MainActor @Test func completionFailsClosedAndCannotBeOpened() throws {
        let database = try DatabaseManager()
        _ = try ProfileRepository(database).ensureDefault()
        let service = DownloadService(repository: DownloadRepository(database))
        var record = DownloadRecord(profileID: BrowserProfile.defaultID, tabID: nil, url: "https://example.com/file")
        record.destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        DownloadService.verifyCompletion(&record, downloadURL: nil, originURL: nil)
        #expect(record.state == .failed && record.error != nil)
        #expect(throws: (any Error).self) { try service.open(record) }
    }
    @Test func rejectsMissingFileAndSymlinkWithoutChangingTarget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("missing")
        #expect(throws: (any Error).self) { try DownloadQuarantine.enforce(at: missing, downloadURL: nil, originURL: nil) }
        let target = root.appendingPathComponent("target")
        try Data("fixture".utf8).write(to: target)
        let before = try DownloadQuarantine.properties(at: target)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: (any Error).self) { try DownloadQuarantine.enforce(at: link, downloadURL: nil, originURL: nil) }
        #expect(NSDictionary(dictionary: try DownloadQuarantine.properties(at: target)).isEqual(to: before))
    }
}
