import Foundation
import CoreFoundation

/// Dictionaries exist only at the JSON Schema validation boundary, never as the stored answer model.
enum AnswerProtocol {
    static var schema: [String: Any] {
        guard let url = Bundle.main.url(forResource: "OrigamiAnswerV1.schema", withExtension: "json"), let data = try? Data(contentsOf: url), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }
    static func schema(visuals: Bool) -> [String: Any] {
        var result = schema
        if !visuals, var properties = result["properties"] as? [String: Any], var blocks = properties["blocks"] as? [String: Any], var items = blocks["items"] as? [String: Any], var variants = items["anyOf"] as? [[String: Any]] {
            variants.removeAll { typeName($0) == "generated_visual" }; items["anyOf"] = variants; blocks["items"] = items; properties["blocks"] = blocks; result["properties"] = properties
        }
        return result
    }
    private static func typeName(_ schema: [String: Any]) -> String? { ((schema["properties"] as? [String: Any])?["type"] as? [String: Any])?["enum"].flatMap { ($0 as? [String])?.first } }
    static func conforms(_ value: Any, to schema: [String: Any], depth: Int = 0) -> Bool {
        guard depth < 24 else { return false }
        if let alternatives = schema["anyOf"] as? [[String: Any]] { return alternatives.contains { conforms(value, to: $0, depth: depth + 1) } }
        let types = schema["type"] as? [String] ?? [schema["type"] as? String ?? ""]
        if value is NSNull { return types.contains("null") }
        if let options = schema["enum"] as? [String], let string = value as? String, !options.contains(string) { return false }
        if let options = schema["enum"] as? [Int], let number = value as? NSNumber, !options.contains(number.intValue) { return false }
        switch types.first {
        case "object":
            guard let object = value as? [String: Any], let properties = schema["properties"] as? [String: [String: Any]], let required = schema["required"] as? [String], Set(required).isSubset(of: Set(object.keys)), Set(object.keys).isSubset(of: Set(properties.keys)) else { return false }
            return object.allSatisfy { conforms($0.value, to: properties[$0.key] ?? [:], depth: depth + 1) }
        case "array": guard let items = value as? [Any], items.count <= 200, let item = schema["items"] as? [String: Any] else { return false }; return items.allSatisfy { conforms($0, to: item, depth: depth + 1) }
        case "string": return (value as? String).map { $0.utf8.count <= 100_000 } ?? false
        case "integer": guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return false }; return n.doubleValue.isFinite && n.doubleValue.rounded() == n.doubleValue
        default: return false
        }
    }
    static func decode(_ text: String, visuals: Bool, isPrivate: Bool = false) throws -> OrigamiAnswerV1 {
        guard text.utf8.count <= 1_000_000, let data = text.data(using: .utf8), var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw AIError.invalidJSON }
        guard let blocks = object["blocks"] as? [[String: Any]] else { throw AIError.answerSchema }
        let variants = (((schema["properties"] as? [String: Any])?["blocks"] as? [String: Any])?["items"] as? [String: Any])?["anyOf"] as? [[String: Any]] ?? []
        VisualDiagnostics.shared.capture(text, blocks: blocks, isPrivate: isPrivate)
        object["blocks"] = blocks.compactMap { block -> [String: Any]? in
            guard block["type"] as? String == "generated_visual" else { return block }
            guard visuals else { VisualDiagnostics.shared.record("schema.visuals_disabled"); return nil }
            guard let visualSchema = variants.first(where: { typeName($0) == "generated_visual" }), conforms(block, to: visualSchema), let data = try? JSONSerialization.data(withJSONObject: block), let visual = try? JSONDecoder().decode(AnswerVisual.self, from: data) else {
                let fields = ["type", "title", "html", "css", "javascript"]
                let invalid = fields.filter { !(block[$0] is String) }.joined(separator: ",")
                let extras = block.keys.filter { !fields.contains($0) }.count
                VisualDiagnostics.shared.record("schema.invalid_visual_fields missing_or_nonstring=\(invalid) extra_count=\(extras)")
                return ["type": "generated_visual", "title": "", "html": "", "css": "", "javascript": ""]
            }
            if let reason = VisualPolicy.rejection(visual) {
                VisualDiagnostics.shared.record(reason)
                return ["type": "generated_visual", "title": visual.title, "html": "", "css": "", "javascript": ""]
            }
            VisualDiagnostics.shared.record("validation.accepted")
            return block
        }
        guard conforms(object, to: schema(visuals: visuals)) else { throw AIError.answerSchema }
        var answer = try JSONDecoder().decode(OrigamiAnswerV1.self, from: JSONSerialization.data(withJSONObject: object))
        guard answer.schema_version == 1, !answer.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, Set(answer.sources.map(\.id)).count == answer.sources.count else { throw AIError.answerSchema }
        answer.sources.removeAll { $0.id.isEmpty || $0.id.count > 100 || AISource.safeURL($0.url) == nil || ($0.canonical_url != nil && AISource.safeURL($0.canonical_url!) == nil) }
        for index in answer.blocks.indices {
            if case .table(let table) = answer.blocks[index], table.columns.isEmpty || table.rows.contains(where: { $0.count != table.columns.count }) { throw AIError.answerSchema }
            answer.blocks[index].filterCitations(Set(answer.sources.map(\.id)))
        }
        return answer
    }
    static func apply(_ result: AIProviderResult, to event: inout AISearchEvent, input: AIRequest, isFinal: Bool = true) throws {
        var answer = try decode(result.text, visuals: input.generatedVisuals, isPrivate: input.isPrivate)
        guard answer.mode == input.mode.rawValue.lowercased() else { throw AIError.answerSchema }
        answer.query = input.query
        let evidence = Set(result.sources.map(\.url) + input.contexts.map(\.url))
        // Sources must have a provider/supplied evidence origin; generated URLs alone are not proof.
        answer.sources.removeAll { !evidence.contains($0.url) && !($0.canonical_url.map(evidence.contains) ?? false) }
        for index in answer.sources.indices {
            if !evidence.contains(answer.sources[index].url), let canonical = answer.sources[index].canonical_url { answer.sources[index].url = canonical }
            answer.sources[index].provenance = result.sources.contains { $0.url == answer.sources[index].url } ? "Provider retrieval" : "Explicitly supplied page"
        }
        for index in answer.blocks.indices { answer.blocks[index].filterCitations(Set(answer.sources.map(\.id))) }
        // Retain retrieval evidence even when the model omitted it from its source registry.
        // These entries are not assigned to claims by guessing.
        for source in result.sources where AISource.safeURL(source.url) != nil && !answer.sources.contains(where: { $0.url == source.url }) {
            var id = "retrieved_" + String(answer.sources.count + 1)
            while answer.sources.contains(where: { $0.id == id }) { id += "_" }
            answer.sources.append(AnswerSource(id: id, url: source.url, title: source.title, source_type: .unknown, provenance: "Provider retrieval · not linked to a claim"))
        }
        if isFinal && input.action.needsWeb && answer.sources.isEmpty { answer.blocks.insert(.callout(AnswerText(text: "The provider returned no web sources for this answer.", citations: [])), at: 0) }
        if let model = result.answeredModel { event.model = model }
        event.fallbackDisclosure = result.fallbackDisclosure
        if input.action == .credibility {
            let hasEvidence = result.sources.contains { AISource.safeURL($0.url) != nil && !input.contexts.map(\.url).contains($0.url) }
            event.credibility = hasEvidence ? CredibilityState.allCases.first { answer.summary.hasPrefix($0.rawValue) } ?? .unknown : .unknown
            if event.credibility == .unknown { answer.summary = "Unable to Assess. Insufficient verified evidence to assign a credibility rating." }
        }
        event.answerV1 = answer; event.generatedVisuals = input.generatedVisuals
        event.providerSources = result.sources; event.citations = result.citations
        event.blocks = []; event.markdown = nil; event.sources = []
        event.usage = result.usage; event.searchSuggestions = result.suggestions; event.status = "Complete"
    }
}
