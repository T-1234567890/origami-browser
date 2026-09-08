import Foundation

enum AnswerGrammar {
    static func blocks(_ result: AIProviderResult, contexts: [AIPageContext]) -> [AIBlock] {
        let permitted = Set(result.sources.map(\.url) + contexts.map(\.url))
        var paragraphs: [String] = []
        var buffer: [String] = []; var code = false
        for line in result.text.components(separatedBy: "\n") {
            if line.hasPrefix("```") { code.toggle(); buffer.append(line); continue }
            if line.trimmingCharacters(in: .whitespaces).isEmpty && !code {
                if !buffer.isEmpty { paragraphs.append(buffer.joined(separator: "\n")); buffer = [] }
            } else { buffer.append(line) }
        }
        if !buffer.isEmpty { paragraphs.append(buffer.joined(separator: "\n")) }
        var blocks: [AIBlock] = []
        for paragraph in paragraphs.prefix(300) {
            let text = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            var kind = AIBlock.Kind.prose
            if text.hasPrefix("#") { kind = .heading }
            else if text.hasPrefix("```") { kind = .code }
            else if text.hasPrefix("- ") || text.hasPrefix("* ") { kind = .points }
            else if text.range(of: "^[0-9]+\\. ", options: .regularExpression) != nil { kind = .steps }
            else if text.hasPrefix(">") { kind = .callout }
            let rows = text.split(separator: "\n").filter { $0.contains("|") }.map { $0.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) } }.filter { row in !row.allSatisfy { $0.allSatisfy { "-: ".contains($0) } } }
            if rows.count >= 2, text.contains("---") { kind = .table }
            var cited = Set(result.citations.filter { !$0.excerpt.isEmpty && (text.contains($0.excerpt) || $0.excerpt.contains(text)) }.map(\.sourceURL))
            for url in permitted where text.contains(url) { cited.insert(url) }
            let cleaned = text.replacingOccurrences(of: #"\[\[?\d+\]?\]\(https?://[^)]+\)"#, with: "", options: .regularExpression).replacingOccurrences(of: #"\[([^\]]+)\]\((https?://[^)]+)\)"#, with: "$1", options: .regularExpression)
            blocks.append(AIBlock(kind: kind, text: cleaned, rows: rows, sourceURLs: Array(cited.intersection(permitted)).sorted()))
        }
        return blocks
    }
    static func apply(_ result: AIProviderResult, to event: inout AISearchEvent, contexts: [AIPageContext]) {
        event.markdown = result.text
        event.sources = result.sources
        for context in contexts where AISource.safeURL(context.url) != nil && !event.sources.contains(where: { $0.url == context.url }) {
            event.sources.append(AISource(url: context.url, title: context.title, provenance: "Supplied page — not independently verified"))
        }
        event.blocks = blocks(result, contexts: contexts); event.citations = result.citations
        event.usage = result.usage; event.searchSuggestions = result.suggestions
        let first = result.text.components(separatedBy: "\n").first?.trimmingCharacters(in: CharacterSet(charactersIn: "#* .:")) ?? ""
        let retrieved = Set(result.sources.map(\.url))
        let linkedEvidence = event.blocks.contains { !$0.sourceURLs.filter { retrieved.contains($0) }.isEmpty }
        if event.action == .credibility { event.credibility = !linkedEvidence ? .unknown : CredibilityState.allCases.first { first.hasPrefix($0.rawValue) } ?? .unknown }
        if event.action == .verify { event.verification = !linkedEvidence ? .unknown : VerificationState.allCases.first { first.hasPrefix($0.rawValue) } ?? .unknown }
        if event.action == .credibility || event.action == .verify {
            let replacement = event.credibility?.rawValue ?? event.verification?.rawValue ?? ""
            if let index = event.blocks.firstIndex(where: { $0.kind != .callout }), first == event.blocks[index].text.trimmingCharacters(in: CharacterSet(charactersIn: "#* .:")) {
                event.blocks[index].text = replacement
            }
            if event.action == .credibility {
                for index in event.blocks.indices { event.blocks[index].text = event.blocks[index].text.replacingOccurrences(of: #"\b\d{1,3}\s*/\s*100\b"#, with: "numeric score omitted", options: .regularExpression) }
            }
        }
        if event.mode != .ask && event.action.needsWeb && result.sources.count == 1 {
            event.blocks.insert(AIBlock(kind: .callout, text: "Only one web source was returned. Independent cross-checking is limited."), at: 0)
        }
        if event.action.needsWeb && result.sources.isEmpty {
            event.blocks.insert(AIBlock(kind: .callout, text: "No web evidence was returned. This answer has not been verified against public sources."), at: 0)
        }
        if event.action == .credibility || event.action == .verify { event.markdown = event.blocks.map(\.text).joined(separator: "\n\n") }
        event.status = "Complete"
    }
}
