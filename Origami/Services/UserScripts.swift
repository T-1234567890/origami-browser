import Foundation
import GRDB
import WebKit

struct UserScript: Identifiable, Codable, Equatable {
    var id = UUID().uuidString
    var name = "New Script"
    var source = ""
    var patterns = "https://example.com/*"
    var enabled = false
    var start = false
    static func matches(_ pattern: String, url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme), !pattern.isEmpty else { return false }
        let target = pattern.contains("://") ? url.absoluteString : (url.host ?? "")
        let regex = "^" + NSRegularExpression.escapedPattern(for: pattern).replacingOccurrences(of: "\\*", with: ".*") + "$"
        return target.range(of: regex, options: .regularExpression) != nil
    }
    var wrapper: String {
        let list = patterns.split(whereSeparator: \.isNewline).map { raw in
            let pattern = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return ["regex": "^" + NSRegularExpression.escapedPattern(for: String(pattern)).replacingOccurrences(of: "\\*", with: ".*") + "$", "full": pattern.contains("://") ? "yes" : "no"]
        }
        let encoded = String(data: try! JSONEncoder().encode(list), encoding: .utf8)!
        return """
        /* Origami user script */
        (() => {
          if (!['http:','https:'].includes(location.protocol)) return;
          const patterns = \(encoded);
          const matched = patterns.some(p => new RegExp(p.regex).test(p.full === 'yes' ? location.href : location.hostname));
          if (!matched) return;
          \(source)
        })();
        """
    }
}

final class PowerRepository {
    let database: DatabaseManager
    init(_ database: DatabaseManager) { self.database = database }
    func scripts(_ profile: UUID) throws -> [UserScript] {
        try database.queue.read { db in try Data.fetchAll(db, sql: "SELECT payload FROM user_scripts WHERE profile_id=? ORDER BY name", arguments: [profile.uuidString]).map { try JSONDecoder().decode(UserScript.self, from: $0) } }
    }
    func save(_ script: UserScript, profile: UUID) throws {
        guard !script.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, script.source.utf8.count <= 262144,
              !script.patterns.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RepositoryError.invalidInput }
        let data = try JSONEncoder().encode(script)
        try database.queue.write { db in try db.execute(sql: "INSERT INTO user_scripts(id,profile_id,name,payload) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,payload=excluded.payload WHERE profile_id=excluded.profile_id", arguments: [script.id, profile.uuidString, script.name, data]) }
    }
    func remove(_ script: UserScript, profile: UUID) throws {
        try database.queue.write { db in try db.execute(sql: "DELETE FROM user_scripts WHERE id=? AND profile_id=?", arguments: [script.id, profile.uuidString]) }
    }

}

@MainActor enum ScriptRuntime {
    static func install(_ scripts: [UserScript], controller: WKUserContentController) {
        let existing = controller.userScripts.filter { !$0.source.hasPrefix("/* Origami user script */") }
        controller.removeAllUserScripts()
        existing.forEach(controller.addUserScript)
        for script in scripts where script.enabled {
            controller.addUserScript(WKUserScript(source: script.wrapper, injectionTime: script.start ? .atDocumentStart : .atDocumentEnd, forMainFrameOnly: true, in: .world(name: "Origami.UserScript." + script.id)))
        }
    }
    static func run(_ script: UserScript, page: TabPage) async throws -> String {
        guard page.nativePage == nil, let url = page.currentURL,
              script.patterns.split(whereSeparator: \.isNewline).contains(where: { UserScript.matches(String($0).trimmingCharacters(in: .whitespacesAndNewlines), url: url) }) else { throw RepositoryError.invalidInput }
        let value = try await page.webView.callAsyncJavaScript(script.source, arguments: [:], in: nil, contentWorld: .world(name: "Origami.UserScript." + script.id))
        return value.map { String(describing: $0) } ?? "Script finished."
    }
    static let builtins: [UserScript] = [
        UserScript(name: "Copy Page as Markdown", source: "return '# ' + document.title + '\\n\\n' + document.body.innerText;", patterns: "https://*\nhttp://*"),
        UserScript(name: "Extract Links", source: "return Array.from(document.links, a => a.textContent.trim() + ' — ' + a.href).join('\\n');", patterns: "https://*\nhttp://*"),
        UserScript(name: "Remove Sticky Elements", source: "let n=0; for(const e of document.querySelectorAll('body *')) {if(['fixed','sticky'].includes(getComputedStyle(e).position)){e.style.display='none';n++;}} return n + ' elements hidden until reload.';", patterns: "https://*\nhttp://*"),
        UserScript(name: "Extract Metadata", source: "return JSON.stringify(Array.from(document.querySelectorAll('meta'), m => ({name:m.name || m.getAttribute('property'),content:m.content})),null,2);", patterns: "https://*\nhttp://*")
    ]
}
