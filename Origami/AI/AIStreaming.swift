import Foundation

extension ProviderWire {
    static func streamingRequest(_ provider: AIProviderID, _ input: AIRequest, _ key: String) throws -> URLRequest {
        var request = try Self.request(provider, input, key)
        if provider == .gemini {
            request.url = URL(string: request.url!.absoluteString.replacingOccurrences(of: ":generateContent", with: ":streamGenerateContent?alt=sse"))
        } else {
            var body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            body["stream"] = true
            if provider == .openRouter { body["stream_options"] = ["include_usage": true] }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        return request
    }
}

/// Accumulates public provider stream events, retaining final grounding metadata.
struct AIStreamAccumulator {
    let provider: AIProviderID
    init(provider: AIProviderID) { self.provider = provider }
    private(set) var text = ""
    private var annotations: [[String: Any]] = []
    private var grounding: [String: Any] = [:]
    private var usage: [String: Any] = [:]
    private var finalResponse: [String: Any]?
    private var finished = false
    private var finishReason = ""
    mutating func consume(_ payload: String) throws {
        if payload == "[DONE]" { return }
        guard let data = payload.data(using: .utf8), let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIError.response }
        if let error = root["error"] {
            let body = (try? JSONSerialization.data(withJSONObject: error, options: [.fragmentsAllowed])) ?? Data()
            throw AIAvailability.error(status: (error as? [String: Any])?["code"] as? Int ?? 200, body: body)
        }
        switch provider {
        case .openAI, .xAI:
            switch root["type"] as? String {
            case "response.output_text.delta": text += root["delta"] as? String ?? ""
            case "response.completed": finalResponse = root["response"] as? [String: Any]; finished = finalResponse != nil
            case "response.failed", "error":
                let body = (try? JSONSerialization.data(withJSONObject: (root["response"] as? [String: Any])?["error"] ?? [:])) ?? Data()
                throw AIAvailability.error(status: 200, body: body)
            case "response.incomplete": throw AIError.response
            default: break
            }
        case .openRouter:
            if let value = root["usage"] as? [String: Any] { usage = value }
            if let choice = (root["choices"] as? [[String: Any]])?.first {
                let delta = choice["delta"] as? [String: Any] ?? [:]
                text += delta["content"] as? String ?? ""
                annotations += delta["annotations"] as? [[String: Any]] ?? []
                if let message = choice["message"] as? [String: Any] {
                    annotations += message["annotations"] as? [[String: Any]] ?? []
                    if let complete = message["content"] as? String, !complete.isEmpty { text = complete }
                }
                annotations += choice["annotations"] as? [[String: Any]] ?? []
                if let reason = choice["finish_reason"] as? String {
                    if reason == "length" { throw AIError.truncated }
                    guard reason == "stop" else { throw AIError.response }
                    finishReason = reason; finished = true
                }
            }
        case .gemini:
            if let value = root["usageMetadata"] as? [String: Any] { usage = value }
            if let candidate = (root["candidates"] as? [[String: Any]])?.first {
                let content = candidate["content"] as? [String: Any] ?? [:]
                text += (content["parts"] as? [[String: Any]] ?? []).filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
                if let value = candidate["groundingMetadata"] as? [String: Any] { grounding.merge(value) { _, new in new } }
                if let reason = candidate["finishReason"] as? String {
                    if reason == "MAX_TOKENS" { throw AIError.truncated }
                    guard reason == "STOP" else { throw AIError.response }
                    finishReason = reason; finished = true
                }
            }
        }
    }
    var partial: AIProviderResult { (try? decoded()) ?? AIProviderResult(text: text, sources: [], citations: [], searched: false) }
    func result() throws -> AIProviderResult {
        guard finished else { throw AIError.response }
        return try decoded()
    }
    private func decoded() throws -> AIProviderResult {
        let root: [String: Any]
        switch provider {
        case .openAI, .xAI: root = finalResponse ?? [:]
        case .openRouter: root = ["choices": [["finish_reason": finishReason, "message": ["content": text, "annotations": annotations]]], "usage": usage]
        case .gemini: root = ["candidates": [["finishReason": finishReason, "content": ["parts": [["text": text]]], "groundingMetadata": grounding]], "usageMetadata": usage]
        }
        return try ProviderWire.parse(provider, JSONSerialization.data(withJSONObject: root))
    }
}
