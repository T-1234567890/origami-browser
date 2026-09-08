import Foundation
import SwiftUI
import WebKit
import GRDB
import Testing
@testable import Origami

@MainActor struct PreReleaseSecurityTests {
    @Test func privateRequestsDoNotPersistCapabilityState() async throws {
        for privateMode in [true, false] {
            let name = "Origami.SecurityFixture." + UUID().uuidString
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            let settings = AISettings(defaults: defaults)
            var input = AIRequest(query: "Synthetic fixture", mode: .ask, action: .web, contexts: [], model: "fixture")
            input.isPrivate = privateMode
            let before = defaults.persistentDomain(forName: name) ?? [:]
            _ = try await FallbackAIClient(base: SecurityAnswerFixture(), settings: settings).answer(provider: .openRouter, input: input)
            let after = defaults.persistentDomain(forName: name) ?? [:]
            let keys = after.keys.filter { $0.hasPrefix("ai.compatibility.") }
            #expect(privateMode ? keys.isEmpty : keys.count == 2)
            if privateMode { #expect(NSDictionary(dictionary: before).isEqual(to: after)) }
        }
    }
    @Test func privateDecodingSkipsRawCapture() throws {
        #if DEBUG
        let publicAnswer = answerFixture("Public fixture")
        _ = try AnswerProtocol.decode(publicAnswer, visuals: true)
        let before = VisualDiagnostics.shared.rawResponse
        let visualBefore = VisualDiagnostics.shared.rawVisualPayloads
        var input = AIRequest(query: "Private synthetic fixture", mode: .ask, action: .web, contexts: [], model: "fixture")
        input.isPrivate = true; input.generatedVisuals = true
        var event = AISearchEvent(query: input.query, mode: .ask, action: .web, provider: .openRouter, model: "fixture")
        let privateText = answerFixture(input.query, blocks: [["type":"generated_visual", "title":"Fixture", "html":"<div>Private synthetic visual</div>", "css":"", "javascript":""]])
        try AnswerProtocol.apply(AIProviderResult(text: privateText, sources: [], citations: [], searched: true), to: &event, input: input)
        #expect(VisualDiagnostics.shared.rawResponse == before)
        #expect(VisualDiagnostics.shared.rawVisualPayloads == visualBefore)
        #expect(before == publicAnswer)
        _ = try AnswerProtocol.decode(privateText, visuals: true)
        #expect(VisualDiagnostics.shared.rawResponse == privateText)
        #expect(VisualDiagnostics.shared.rawVisualPayloads.count == 1)
        #endif
    }
    @Test func downloadURLsAreSanitizedAtPersistenceBoundary() throws {
        let database = try DatabaseManager(); let profile = try ProfileRepository(database).ensureDefault()
        let repository = DownloadRepository(database)
        for raw in ["https://example.com/file?token=synthetic", "https://example.com/file#fragment", "https://user:fixture@example.com/file", "https://example.com/file"] {
            let record = DownloadRecord(profileID: profile.id, tabID: nil, url: raw)
            try repository.save(record)
            #expect(try repository.list(profileID: profile.id, id: record.id).first?.url == "https://example.com/file")
            #expect(record.url == raw) // Active transfer input is untouched.
            try database.queue.write { try $0.execute(sql: "UPDATE downloads SET url=? WHERE id=?", arguments: [raw, record.id.uuidString]) }
            try repository.recoverInterrupted()
            #expect(try repository.list(profileID: profile.id, id: record.id).first?.url == "https://example.com/file")
        }
    }
    @Test func databasePermissionsAndWALRemainFunctional() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fixture.sqlite")
        let database = try DatabaseManager(fileURL: file)
        try database.queue.write { try $0.execute(sql: "CREATE TABLE security_fixture(value TEXT); INSERT INTO security_fixture VALUES ('synthetic')") }
        #expect(try database.queue.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") } == "wal")
        #expect(try mode(directory) == 0o700)
        for path in [file.path, file.path + "-wal", file.path + "-shm"] { #expect(try mode(URL(fileURLWithPath: path)) == 0o600) }
        let reopened = try DatabaseManager(fileURL: file)
        #expect(try reopened.queue.read { try String.fetchOne($0, sql: "SELECT value FROM security_fixture") } == "synthetic")
        try reopened.queue.write { try $0.execute(sql: "INSERT INTO security_fixture VALUES ('second')") }
        #expect(try database.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM security_fixture") } == 2)
    }
    @Test func insecureExistingStorageTightenedAndSymlinksRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("fixture.sqlite")
        try Data().write(to: file)
        try FileManager.default.setAttributes([.posixPermissions:0o755], ofItemAtPath: directory.path)
        try FileManager.default.setAttributes([.posixPermissions:0o644], ofItemAtPath: file.path)
        _ = try DatabaseManager(fileURL: file)
        #expect(try mode(directory) == 0o700 && mode(file) == 0o600)
        let link = directory.appendingPathComponent("link.sqlite")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: DatabaseStorageProtection.Failure.self) { _ = try DatabaseManager(fileURL: link) }
    }
    private func mode(_ file: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
    @Test func pathologicalScriptsAndWorkersAreRejected() {
        for js in ["for/**/(;;){}", "for\n(;;){}", "while(true){}", "new Worker('remote')", "new SharedWorker('remote')", "WebAssembly.compile(bytes)"] {
            #expect(!VisualPolicy.valid(AnswerVisual(title: "Fixture", html: "<div>Fixture</div>", css: "", javascript: js)))
        }
    }
    @Test func blockedExecutionDisposesEnvironmentAndFreshVisualWorks() async throws {
        var height: CGFloat = 0
        let host = VisualWebHost.Host()
        let coordinator = VisualWebHost.Coordinator(height: Binding(get: { height }, set: { height = $0 }))
        install(host, coordinator)
        defer { coordinator.dispose() }
        try await wait { height > 0 || coordinator.failed }
        #expect(!coordinator.failed)
        weak var discarded = host.web
        // Bounded pathological fixture bypasses admission intentionally to test
        // the renderer watchdog. It stops after 3 seconds even on test failure.
        host.web?.evaluateJavaScript("const end = Date.now()+3000; while(Date.now()<end) {}") { _, _ in }
        try await wait { coordinator.failed }
        #expect(height == 0 && coordinator.web == nil && host.web == nil && host.subviews.isEmpty)
        #expect(coordinator.timer == nil && coordinator.pending == nil)
        try await wait { discarded == nil }
        var nextHeight: CGFloat = 0
        let next = VisualWebHost.Coordinator(height: Binding(get: { nextHeight }, set: { nextHeight = $0 }))
        let nextHost = VisualWebHost.Host(); install(nextHost, next)
        defer { next.dispose() }
        try await wait { nextHeight > 0 || next.failed }
        #expect(nextHeight == 80 && !next.failed)
    }
    private func install(_ host: VisualWebHost.Host, _ coordinator: VisualWebHost.Coordinator) {
        host.web = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 480), configuration: VisualPolicy.configuration())
        host.addSubview(host.web!); coordinator.host = host; coordinator.web = host.web
        host.web?.navigationDelegate = coordinator; host.web?.uiDelegate = coordinator
        host.web?.loadHTMLString(VisualPolicy.document(AnswerVisual(title: "Fixture", html: "<div>Normal synthetic diagram</div>", css: "#visual {height:80px}", javascript: "")), baseURL: nil)
        coordinator.start()
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<100 { if condition() { return }; try await Task.sleep(for: .milliseconds(100)) }
        Issue.record("Security fixture timed out"); throw AIError.response
    }
}
private struct SecurityAnswerFixture: AIAnswerClient {
    func answer(provider: AIProviderID, input: AIRequest) async throws -> AIProviderResult {
        AIProviderResult(text: answerFixture(input.query), sources: [], citations: [], searched: true)
    }
}
