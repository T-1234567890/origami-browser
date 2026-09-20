import Foundation

/// This code is MPL-2.0. Runtime filter data and its conversions are CC BY-SA 3.0-or-later.
enum BlockingKind: String, CaseIterable { case content, ads }
struct BlockingRule: Codable, Equatable, Sendable {
    struct Trigger: Codable, Equatable, Sendable {
        var urlFilter: String
        var resourceType: [String]?
        var loadType: [String]?
        var ifDomain: [String]?
        var unlessDomain: [String]?
        var ifTopURL: [String]?
        enum CodingKeys: String, CodingKey {
            case urlFilter = "url-filter", resourceType = "resource-type", loadType = "load-type"
            case ifDomain = "if-domain", unlessDomain = "unless-domain", ifTopURL = "if-top-url"
        }
    }
    struct Action: Codable, Equatable, Sendable { var type: String }
    var trigger: Trigger
    var action: Action
    static func exception(host: String) -> Self {
        Self(trigger: .init(urlFilter: ".*", ifTopURL: ["^https?://" + escaped(host) + "(:[0-9]+)?/"]), action: .init(type: "ignore-previous-rules"))
    }
    static func escaped(_ text: String) -> String {
        text.reduce("") { $0 + (".\\+?()[]{}$^|".contains($1) ? "\\" : "") + String($1) }
    }
}
enum UserContentRules {
    /// Empty by default. Each user domain blocks that host and its subdomains.
    static func rules(domains: [String]) -> [BlockingRule] {
        domains.filter(FilterConverter.validHost).map {
            .init(trigger: .init(urlFilter: "^https?://([a-z0-9-]+\\.)*" + BlockingRule.escaped($0) + "[:/]"), action: .init(type: "block"))
        }
    }
}
struct FilterConversion: Sendable {
    var rules: [BlockingRule]
    var skipped: Int
}
enum FilterConverter {
    enum Failure: Error { case invalidList, tooManyRules }
    static func convert(_ lists: [String]) throws -> FilterConversion {
        guard lists.count == 2, lists.allSatisfy({ $0.hasPrefix("[Adblock") && $0.utf8.count <= 12_000_000 }) else { throw Failure.invalidList }
        let lines = lists.flatMap { $0.components(separatedBy: .newlines) }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let disabled = Set(lines.filter { $0.hasSuffix("$badfilter") || $0.hasSuffix(",badfilter") }.map { $0.replacingOccurrences(of: ",badfilter", with: "").replacingOccurrences(of: "$badfilter", with: "") })
        var blocks: [BlockingRule] = [], exceptions: [BlockingRule] = [], skipped = 0
        var seen = Set<String>()
        for line in lines {
            guard !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix("["), seen.insert(line).inserted else { continue }
            guard !disabled.contains(line), !line.contains("badfilter"), line.count <= 2048,
                  !line.contains("#"), let rule = parse(line) else { skipped += 1; continue }
            if rule.action.type == "block" { blocks.append(rule) } else { exceptions.append(rule) }
            guard blocks.count + exceptions.count <= 120_000 else { throw Failure.tooManyRules }
        }
        guard !blocks.isEmpty else { throw Failure.invalidList }
        // Exceptions follow all network blocks, including those from the other subscription.
        return FilterConversion(rules: blocks + exceptions, skipped: skipped)
    }
    static func parse(_ text: String) -> BlockingRule? {
        let allow = text.hasPrefix("@@")
        let value = allow ? String(text.dropFirst(2)) : text
        let parts = value.split(separator: "$", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first, !first.isEmpty else { return nil }
        var pattern = String(first)
        guard !(pattern.hasPrefix("/") && pattern.hasSuffix("/")), !pattern.contains("\\"), pattern.unicodeScalars.allSatisfy({ $0.isASCII }) else { return nil }
        var trigger = BlockingRule.Trigger(urlFilter: "")
        if parts.count == 2 {
            var types: [String] = []
            for option in parts[1].split(separator: ",") {
                switch option {
                case "third-party", "3p": trigger.loadType = ["third-party"]
                case "~third-party", "~3p": trigger.loadType = ["first-party"]
                case "script", "image", "font", "media": types.append(String(option))
                case "stylesheet": types.append("style-sheet")
                case "xmlhttprequest": types.append("raw")
                default:
                    if option.hasPrefix("domain=") {
                        let domains = option.dropFirst(7).split(separator: "|")
                        let included = domains.filter { !$0.hasPrefix("~") }.map(String.init)
                        let excluded = domains.filter { $0.hasPrefix("~") }.map { String($0.dropFirst()) }
                        guard !domains.isEmpty, (included + excluded).allSatisfy(validHost), included.isEmpty || excluded.isEmpty else { return allow ? broadException(pattern) : nil }
                        trigger.ifDomain = included.isEmpty ? nil : included.map { "*" + $0 }
                        trigger.unlessDomain = excluded.isEmpty ? nil : excluded.map { "*" + $0 }
                    } else {
                        // Broaden unsupported exceptions, never unsupported blocking rules.
                        // This may allow extra requests but avoids breaking sites by dropping an exception.
                        return allow ? broadException(pattern) : nil
                    }
                }
            }
            if !types.isEmpty { trigger.resourceType = types }
        }
        var prefix = "", suffix = ""
        if pattern.hasPrefix("||") { prefix = "^https?://([a-z0-9-]+\\.)*"; pattern.removeFirst(2) }
        else if pattern.hasPrefix("|") { prefix = "^"; pattern.removeFirst() }
        if pattern.hasSuffix("|") { suffix = "$"; pattern.removeLast() }
        guard pattern.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        trigger.urlFilter = prefix + pattern.reduce("") { result, char in
            result + (char == "*" ? ".*" : char == "^" ? "[^a-zA-Z0-9_.%-]" : BlockingRule.escaped(String(char)))
        } + suffix
        return .init(trigger: trigger, action: .init(type: allow ? "ignore-previous-rules" : "block"))
    }
    private static func broadException(_ pattern: String) -> BlockingRule? { parse("@@" + pattern) }
    static func validHost(_ host: String) -> Bool {
        !host.isEmpty && host.count <= 253 && host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0.count <= 63 && $0.first != "-" && $0.last != "-" && $0.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }
}
