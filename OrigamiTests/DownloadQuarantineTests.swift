import Foundation
import CoreServices
import Testing
@testable import Origami

struct DownloadQuarantineTests {
    @Test(arguments: ["sample.dmg", "sample.pkg", "sample.app.zip", "sample.zip", "sample.app", "sample.sh", "sample.command", "executable", "sample.pdf", "sample.mp3", "sample.mp4"])
    func allFileTypesReceiveVerifiedQuarantine(_ name: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var stage = "create fixture directory"
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let file = root.appendingPathComponent(name)
            stage = "create inert fixture"
            if name.hasSuffix(".app") { try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true) }
            else { try Data("Inert quarantine fixture. Do not execute.".utf8).write(to: file) }
            let source = URL(string: "https://downloads.example.com/\(name)?token=secret")!
            let origin = URL(string: "https://example.com/downloads#section")!
            stage = "first quarantine enforcement"
            try DownloadQuarantine.enforce(at: file, downloadURL: source, originURL: origin)
            stage = "read quarantine properties"
            let first = try DownloadQuarantine.properties(at: file)
            stage = "read quarantine attribute"
            let attribute = try DownloadQuarantine.attribute("com.apple.quarantine", at: file)
            #expect(!attribute.isEmpty, "\(name): quarantine attribute must exist")
            #expect(!(first[kLSQuarantineAgentNameKey as String] as? String ?? "").isEmpty,
                    "\(name): quarantine agent must exist")
            stage = "read source metadata"
            let metadata = try DownloadQuarantine.attribute("com.apple.metadata:kMDItemWhereFroms", at: file)
            stage = "decode source metadata"
            let origins = try PropertyListSerialization.propertyList(from: metadata, format: nil) as? [String]
            #expect(origins == ["https://downloads.example.com/\(name)", "https://example.com/downloads"],
                    "\(name): source metadata must retain sanitized fixture URLs")
            stage = "repeat quarantine enforcement"
            try DownloadQuarantine.enforce(at: file, downloadURL: source, originURL: origin)
            stage = "read repeated quarantine properties"
            let repeated = try DownloadQuarantine.properties(at: file)
            // Launch Services owns readback: macOS 27 can return a different timestamp
            // after rewriting quarantine. Verify protection, not optional OS metadata equality.
            #expect(!(repeated[kLSQuarantineAgentNameKey as String] as? String ?? "").isEmpty,
                    "\(name): repeated enforcement must retain a quarantine agent")
            stage = "verify repeated quarantine attribute"
            #expect(try !DownloadQuarantine.attribute("com.apple.quarantine", at: file).isEmpty,
                    "\(name): repeated enforcement must retain quarantine")
            stage = "verify repeated sanitized source metadata"
            let repeatedMetadata = try DownloadQuarantine.attribute("com.apple.metadata:kMDItemWhereFroms", at: file)
            let repeatedOrigins = try PropertyListSerialization.propertyList(from: repeatedMetadata, format: nil) as? [String]
            #expect(repeatedOrigins == origins, "\(name): repeated enforcement must retain sanitized sources")
        } catch {
            // Avoid localizedDescription/userInfo: filesystem errors can include user paths.
            let diagnostic = "Quarantine fixture \(name); stage: \(stage); \(Self.safeFailure(error))"
            print(diagnostic)
            Issue.record(Comment(rawValue: diagnostic))
        }
    }

    @Test func preparationPreservesExistingTimestampAndAgent() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000.25)
        let existing: [String: Any] = [
            kLSQuarantineTimeStampKey as String: timestamp,
            kLSQuarantineAgentNameKey as String: "Fixture Downloader",
            kLSQuarantineAgentBundleIdentifierKey as String: "test.example.downloader"
        ]
        let prepared = DownloadQuarantine.preparedProperties(existing: existing, downloadURL: nil, originURL: nil,
                                                            now: timestamp.addingTimeInterval(60))
        #expect(prepared[kLSQuarantineTimeStampKey as String] as? Date == timestamp)
        #expect(prepared[kLSQuarantineAgentNameKey as String] as? String == "Fixture Downloader")
        #expect(prepared[kLSQuarantineAgentBundleIdentifierKey as String] as? String == "test.example.downloader")
    }

    @Test func preparationSuppliesMissingTimestampAndSanitizesSources() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let prepared = DownloadQuarantine.preparedProperties(existing: [:],
            downloadURL: URL(string: "https://downloads.example.com/file?token=fixture"),
            originURL: URL(string: "https://example.com/downloads#section"), now: timestamp)
        #expect(prepared[kLSQuarantineTimeStampKey as String] as? Date == timestamp)
        #expect(prepared[kLSQuarantineTypeKey as String] as? String == kLSQuarantineTypeWebDownload as String)
        #expect(prepared[kLSQuarantineDataURLKey as String] as? URL == URL(string: "https://downloads.example.com/file"))
        #expect(prepared[kLSQuarantineOriginURLKey as String] as? URL == URL(string: "https://example.com/downloads"))
    }

    private static func safeFailure(_ error: Error) -> String {
        if let failure = error as? DownloadQuarantine.Failure {
            switch failure {
            case .invalidDestination: return "invalidDestination"
            case .verificationFailed: return "verificationFailed"
            }
        }
        let error = error as NSError
        let domain = [NSCocoaErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain].contains(error.domain)
            ? error.domain : "Other error domain"
        return "\(domain), code \(error.code)"
    }

    @Test func diagnosticOmitsErrorPayloadAndUnknownDomains() {
        let error = NSError(domain: "private fixture domain", code: 13, userInfo: [
            NSLocalizedDescriptionKey: "sensitive fixture description",
            NSFilePathErrorKey: "sensitive fixture path"
        ])
        #expect(Self.safeFailure(error) == "Other error domain, code 13")
        #expect(Self.safeFailure(NSError(domain: NSPOSIXErrorDomain, code: 13)) == "NSPOSIXErrorDomain, code 13")
        #expect(Self.safeFailure(DownloadQuarantine.Failure.verificationFailed) == "verificationFailed")
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
