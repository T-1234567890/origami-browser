import Foundation

struct AnswerText: Codable, Equatable { var text: String; var citations: [String] }
struct AnswerHeading: Codable, Equatable { var text: String; var level: Int }
struct AnswerList: Codable, Equatable { var items: [AnswerText] }
struct AnswerTable: Codable, Equatable { var title: String; var columns: [String]; var rows: [[String]]; var citations: [String] }
struct AnswerComparison: Codable, Equatable {
    struct Item: Codable, Equatable { var label: String; var text: String; var citations: [String] }
    var title: String; var items: [Item]
}
struct AnswerTimeline: Codable, Equatable {
    struct Item: Codable, Equatable { var date: String; var label: String; var citations: [String] }
    var title: String; var items: [Item]
}
struct AnswerCode: Codable, Equatable { var language: String; var code: String; var citations: [String] }
struct AnswerQuote: Codable, Equatable { var text: String; var attribution: String?; var citations: [String] }
struct AnswerVisual: Codable, Equatable { var title: String; var html: String; var css: String; var javascript: String }
struct AnswerSource: Codable, Identifiable, Equatable {
    enum SourceType: String, Codable { case primary, secondary, documentation, research, government, news, community, unknown }
    var id: String; var url: String; var canonical_url: String?; var title: String
    var publisher: String?; var author: String?; var published_at: String?; var updated_at: String?
    var source_type: SourceType; var provenance: String?
}
struct OrigamiAnswerV1: Codable, Equatable {
    var schema_version: Int
    var query: String
    var mode: String
    var summary: String
    var sources: [AnswerSource]
    var blocks: [AnswerBlockV1]
    enum CodingKeys: String, CodingKey { case schema_version, query, mode, summary, sources, blocks }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schema_version = try values.decode(Int.self, forKey: .schema_version)
        guard schema_version == 1 else { throw AIError.response }
        query = try values.decode(String.self, forKey: .query); mode = try values.decode(String.self, forKey: .mode)
        summary = try values.decode(String.self, forKey: .summary); sources = try values.decode([AnswerSource].self, forKey: .sources)
        blocks = try values.decode([AnswerBlockV1].self, forKey: .blocks)
    }
    func sourceNumber(_ id: String) -> Int? { sources.firstIndex { $0.id == id }.map { $0 + 1 } }
    var plainText: String { ([summary] + blocks.map(\.plainText)).filter { !$0.isEmpty }.joined(separator: "\n\n") }
}
extension AnswerBlockV1 {
    var plainText: String {
        switch self {
        case .heading(let v): v.text
        case .paragraph(let v), .callout(let v): v.text
        case .bullets(let v), .numbered_list(let v), .steps(let v): v.items.map(\.text).joined(separator: "\n")
        case .table(let v): ([v.title, v.columns.joined(separator: " | ")] + v.rows.map { $0.joined(separator: " | ") }).joined(separator: "\n")
        case .comparison(let v): v.title + "\n" + v.items.map { $0.label + ": " + $0.text }.joined(separator: "\n")
        case .timeline(let v): v.title + "\n" + v.items.map { $0.date + ": " + $0.label }.joined(separator: "\n")
        case .code(let v): v.code
        case .quote(let v): v.text + (v.attribution.map { " — " + $0 } ?? "")
        case .generated_visual: ""
        }
    }
    mutating func filterCitations(_ allowed: Set<String>) {
        func clean(_ refs: [String]) -> [String] { var seen = Set<String>(); return refs.filter { allowed.contains($0) && seen.insert($0).inserted } }
        switch self {
        case .paragraph(var v): v.citations = clean(v.citations); self = .paragraph(v)
        case .callout(var v): v.citations = clean(v.citations); self = .callout(v)
        case .bullets(var v): for i in v.items.indices { v.items[i].citations = clean(v.items[i].citations) }; self = .bullets(v)
        case .numbered_list(var v): for i in v.items.indices { v.items[i].citations = clean(v.items[i].citations) }; self = .numbered_list(v)
        case .steps(var v): for i in v.items.indices { v.items[i].citations = clean(v.items[i].citations) }; self = .steps(v)
        case .comparison(var v): for i in v.items.indices { v.items[i].citations = clean(v.items[i].citations) }; self = .comparison(v)
        case .timeline(var v): for i in v.items.indices { v.items[i].citations = clean(v.items[i].citations) }; self = .timeline(v)
        case .table(var v): v.citations = clean(v.citations); self = .table(v)
        case .code(var v): v.citations = clean(v.citations); self = .code(v)
        case .quote(var v): v.citations = clean(v.citations); self = .quote(v)
        case .heading, .generated_visual: break
        }
    }
}
