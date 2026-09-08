import Foundation
import GRDB

struct FollowedFeed: Identifiable { let id: String; let url: String; let title: String; let folder: String }
struct FeedArticle: Identifiable { let id: String; let feedID: String; let title: String; let url: String; let date: Date; let read: Bool }
struct ParsedFeed { var title = ""; var items: [(id: String, title: String, url: String, date: Date)] = [] }

final class FeedParser: NSObject, XMLParserDelegate {
    private var stack: [String] = []
    private var texts: [String] = []
    private var recognizedRoot = false
    private var item: [String: String]?
    private var result = ParsedFeed()
    private let base: URL
    init(base: URL) { self.base = base }
    func parse(_ data: Data) throws -> ParsedFeed {
        guard data.count <= 4_194_304 else { throw RepositoryError.invalidInput }
        let parser = XMLParser(data: data); parser.delegate = self; parser.shouldResolveExternalEntities = false; parser.shouldProcessNamespaces = true
        guard parser.parse(), recognizedRoot, !result.title.isEmpty || !result.items.isEmpty else { throw RepositoryError.invalidInput }
        return result
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if stack.isEmpty { recognizedRoot = ["rss", "feed", "RDF"].contains(name) }
        stack.append(name); texts.append("")
        if name == "item" || name == "entry" { item = [:] }
        if name == "link", item != nil, let href = attributes["href"], attributes["rel"] == nil || attributes["rel"] == "alternate" { item?["link"] = href }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard let index = texts.indices.last, texts[index].count < 100_000 else { return }
        texts[index] += String(string.prefix(100_000 - texts[index].count))
    }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { self.parser(parser, foundCharacters: String(data: CDATABlock, encoding: .utf8) ?? "") }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = (texts.popLast() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = texts.indices.last { texts[index] += String(value.prefix(max(0, 100_000 - texts[index].count))) }
        if name == "entry" || name == "item" {
            if let item, let link = item["link"], let url = URL(string: link, relativeTo: base)?.absoluteURL, ["http", "https"].contains(url.scheme), result.items.count < 1000 {
                let date = Self.date(item["published"] ?? item["pubDate"] ?? item["updated"] ?? "") ?? Date()
                result.items.append((item["id"] ?? item["guid"] ?? url.absoluteString, item["title"] ?? url.host ?? "Article", url.absoluteString, date))
            }
            item = nil
        } else if item != nil, ["title", "link", "guid", "id", "published", "updated", "pubDate"].contains(name), !value.isEmpty {
            item?[name] = value
        } else if item == nil, name == "title", result.title.isEmpty { result.title = value }
        _ = stack.popLast()
    }
    static func date(_ value: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: value) { return date }
        iso.formatOptions.insert(.withFractionalSeconds)
        if let date = iso.date(from: value) { return date }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "dd MMM yyyy HH:mm:ss Z"] {
            formatter.dateFormat = format; if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}

@MainActor final class FeedService {
    let database: DatabaseManager
    private let session = URLSession(configuration: .ephemeral)
    init(database: DatabaseManager) { self.database = database }
    func cancelAll() { session.invalidateAndCancel() }
    func feeds(profile: UUID) throws -> [FollowedFeed] {
        try database.queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM feeds WHERE profile_id=? ORDER BY folder,title", arguments: [profile.uuidString]).map {
                FollowedFeed(id: $0["id"], url: $0["url"], title: $0["title"], folder: $0["folder"])
            }
        }
    }
    func articles(profile: UUID) throws -> [FeedArticle] {
        try database.queue.read { db in
            try Row.fetchAll(db, sql: "SELECT a.* FROM feed_articles a JOIN feeds f ON f.id=a.feed_id WHERE f.profile_id=? ORDER BY published DESC LIMIT 2000", arguments: [profile.uuidString]).map {
                FeedArticle(id: $0["id"], feedID: $0["feed_id"], title: $0["title"], url: $0["url"], date: Date(timeIntervalSince1970: $0["published"]), read: $0["is_read"])
            }
        }
    }
    func follow(_ url: URL, profile: UUID, folder: String = "") async throws {
        guard ["http", "https"].contains(url.scheme), url.user == nil, url.password == nil else { throw RepositoryError.invalidInput }
        let parsed = try await fetch(url)
        let existing = try feeds(profile: profile).first { $0.url == url.absoluteString }
        let id = existing?.id ?? UUID().uuidString
        try await database.queue.write { db in
            try db.execute(sql: "INSERT INTO feeds(id,profile_id,url,title,folder) VALUES(?,?,?,?,?) ON CONFLICT(profile_id,url) DO UPDATE SET title=excluded.title", arguments: [id, profile.uuidString, url.absoluteString, parsed.title.isEmpty ? url.host ?? "Feed" : parsed.title, folder])
        }
        try save(parsed, feed: id)
    }
    func refresh(_ feed: FollowedFeed) async throws {
        guard let url = URL(string: feed.url) else { throw RepositoryError.invalidInput }
        try save(await fetch(url), feed: feed.id)
    }
    private func fetch(_ url: URL) async throws -> ParsedFeed {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), response.expectedContentLength <= 4_194_304 else { throw RepositoryError.invalidInput }
        var data = Data()
        for try await byte in bytes { guard data.count < 4_194_304 else { throw RepositoryError.invalidInput }; data.append(byte) }
        return try FeedParser(base: response.url ?? url).parse(data)
    }
    private func save(_ parsed: ParsedFeed, feed: String) throws {
        try database.queue.write { db in
            for item in parsed.items {
                try db.execute(sql: "INSERT INTO feed_articles(id,feed_id,title,url,published,is_read) VALUES(?,?,?,?,?,0) ON CONFLICT(id) DO UPDATE SET title=excluded.title,url=excluded.url", arguments: [feed + ":" + item.id, feed, item.title, item.url, item.date.timeIntervalSince1970])
            }
        }
    }
    func mark(_ article: FeedArticle, read: Bool) throws { try database.queue.write { db in try db.execute(sql: "UPDATE feed_articles SET is_read=? WHERE id=?", arguments: [read, article.id]) } }
    func folder(_ feed: FollowedFeed, name: String) throws { try database.queue.write { db in try db.execute(sql: "UPDATE feeds SET folder=? WHERE id=?", arguments: [String(name.prefix(80)), feed.id]) } }
    func unfollow(_ feed: FollowedFeed) throws { try database.queue.write { db in try db.execute(sql: "DELETE FROM feeds WHERE id=?", arguments: [feed.id]) } }
    func exportOPML(profile: UUID) throws -> Data {
        func xml(_ text: String) -> String { text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
        let list = try feeds(profile: profile)
        let body = Dictionary(grouping: list, by: \.folder).keys.sorted().map { folder in
            let content = list.filter { $0.folder == folder }.map { "<outline type=\"rss\" text=\"\(xml($0.title))\" xmlUrl=\"\(xml($0.url))\"/>" }.joined()
            return folder.isEmpty ? content : "<outline text=\"\(xml(folder))\">\(content)</outline>"
        }.joined()
        return Data("<?xml version=\"1.0\"?><opml version=\"2.0\"><head><title>Websites I Follow</title></head><body>\(body)</body></opml>".utf8)
    }
}

final class OPMLParser: NSObject, XMLParserDelegate {
    var entries: [(URL, String)] = []
    private var folders: [String] = []
    func parse(_ data: Data) throws -> [(URL, String)] {
        guard data.count <= 2_097_152 else { throw RepositoryError.invalidInput }
        let parser = XMLParser(data: data); parser.delegate = self; parser.shouldResolveExternalEntities = false
        guard parser.parse() else { throw RepositoryError.invalidInput }; return entries
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        guard name == "outline" else { return }
        if let value = attributes["xmlUrl"], let url = URL(string: value), ["http", "https"].contains(url.scheme), entries.count < 1000 {
            entries.append((url, folders.filter { !$0.isEmpty }.joined(separator: "/"))); folders.append("")
        } else { folders.append(attributes["text"] ?? attributes["title"] ?? "") }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { if name == "outline" { _ = folders.popLast() } }
}
