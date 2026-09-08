import Foundation

/// Only normalized error categories leave the networking boundary.
enum AIAvailability {
    static func error(status: Int, body: Data) -> AIError {
        let raw = String(decoding: body.prefix(65_536), as: UTF8.self).lowercased()
        let text = raw + " " + raw.replacingOccurrences(of: "_", with: " ")
        let permanent = ["api key", "api_key", "authentication", "unauthorized", "billing", "credit", "payment", "insufficient_quota", "spending", "budget", "quota_exceeded", "invalid_request", "invalid parameter", "unsupported", "not support", "require_parameters", "context", "token limit", "too many tokens", "schema", "response_format", "safety", "refusal", "content_filter", "moderation", "data policy", "privacy"]
        if [400,401,402,403,422].contains(status) || permanent.contains(where: text.contains) { return .nonRetryable(status) }
        if [429,502,503,504].contains(status) { return .unavailable(status) }
        if [404,408,500,200].contains(status), ["temporarily unavailable", "model unavailable", "no available provider", "no endpoints found", "route unavailable", "upstream timeout", "upstream timed out", "rate limit", "overloaded", "capacity"].contains(where: text.contains) { return .unavailable(status) }
        return .nonRetryable(status)
    }
    static func temporary(_ error: Error) -> Bool {
        if let error = error as? URLError { return error.code == .timedOut }
        guard let error = error as? AIError else { return false }
        switch error { case .unavailable: return true; case .http(let code): return [429,502,503,504].contains(code); default: return false }
    }
    static func diagnostic(_ error: Error) -> String {
        if let error = error as? URLError { return "transport code=\(error.code.rawValue)" }
        if let error = error as? AIError {
            switch error { case .unavailable(let code), .nonRetryable(let code), .http(let code): return "provider status=\(code) temporary=\(temporary(error))"; default: return "non-availability AI error" }
        }
        return "non-availability error"
    }
}

@MainActor struct FallbackAIClient: AIAnswerClient {
    let base: any AIAnswerClient
    let settings: AISettings
    func answer(provider: AIProviderID, input: AIRequest) async throws -> AIProviderResult {
        try await stream(provider: provider, input: input, update: { _ in })
    }
    func stream(provider: AIProviderID, input: AIRequest, update: @escaping @MainActor (AIProviderResult) -> Void) async throws -> AIProviderResult {
        var input = input
        if input.searchEngine == "auto" { input.searchEngine = settings.searchEngine }
        let enabled = settings.automaticFallback(provider: provider)
        let fallback = settings.model("fallback", provider: provider)
        do {
            let result = try await base.stream(provider: provider, input: input, update: update)
            // Never treat protocol errors as model availability failures.
            let answer = try AnswerProtocol.decode(result.text, visuals: input.generatedVisuals, isPrivate: input.isPrivate)
            guard answer.mode == input.mode.rawValue.lowercased() else { throw AIError.answerSchema }
            settings.rememberCompatibility(provider: provider, input: input, result: result)
            return result
        } catch {
            guard enabled, !Task.isCancelled, AIAvailability.temporary(error) else { throw error }
            #if DEBUG
            NSLog("[Origami AI Fallback] Primary failed: %@", AIAvailability.diagnostic(error))
            #endif
            guard !fallback.isEmpty, fallback != input.model,
                  settings.fallbackCompatible(fallback, provider: provider, input: input) else { throw AIError.noCompatibleFallback }
        }
        try Task.checkCancellation()
        var retry = input; retry.model = fallback
        let disclosure = "Answered with \(settings.displayName(fallback)) — default model was unavailable."
        // Outside the catch: a fallback failure propagates without another attempt.
        var result = try await base.stream(provider: provider, input: retry) { partial in
            var partial = partial; partial.answeredModel = fallback; partial.fallbackDisclosure = disclosure
            update(partial)
        }
        let answer = try AnswerProtocol.decode(result.text, visuals: retry.generatedVisuals, isPrivate: retry.isPrivate)
        guard answer.mode == retry.mode.rawValue.lowercased() else { throw AIError.answerSchema }
        guard !retry.action.needsWeb || result.searched else { throw AIError.response }
        settings.rememberCompatibility(provider: provider, input: retry, result: result)
        result.answeredModel = fallback; result.fallbackDisclosure = disclosure
        return result
    }
}

extension AISettings {
    func automaticFallback(provider: AIProviderID) -> Bool { defaultsForFallback.bool(forKey: "ai.autoFallback." + provider.rawValue) }
    var automaticFallback: Bool {
        get { _ = revision; return automaticFallback(provider: provider) }
        set { defaultsForFallback.set(newValue, forKey: "ai.autoFallback." + provider.rawValue); revision += 1 }
    }
    private func compatibilityKey(provider: AIProviderID, model: String, input: AIRequest) -> String {
        "ai.compatibility.v1.\(provider.rawValue).\(model).\(input.mode.rawValue).\(input.action.needsWeb).\(input.generatedVisuals).\(input.searchEngine)"
    }
    private func requestBytes(_ input: AIRequest) -> Int { input.systemInstruction.utf8.count + input.userPayload.utf8.count + input.evidencePayload.utf8.count }
    func rememberCompatibility(provider: AIProviderID, input: AIRequest, result: AIProviderResult) {
        guard !input.isPrivate, !input.action.needsWeb || result.searched else { return }
        let key = compatibilityKey(provider: provider, model: input.model, input: input)
        defaultsForFallback.set(requestBytes(input), forKey: key)
        defaultsForFallback.set(Date().timeIntervalSince1970, forKey: key + ".time")
    }
    func fallbackCompatible(_ model: String, provider: AIProviderID, input: AIRequest) -> Bool {
        let bytes = requestBytes(input)
        let key = compatibilityKey(provider: provider, model: model, input: input)
        let confirmed = defaultsForFallback.integer(forKey: key)
        let age = Date().timeIntervalSince1970 - defaultsForFallback.double(forKey: key + ".time")
        if provider != .openRouter, confirmed >= bytes, age >= 0, age < 7 * 86400 { return true }
        guard provider == .openRouter,
              let models = defaultsForFallback.dictionary(forKey: "ai.fallbackCapabilities." + provider.rawValue),
              let row = models[model] as? [String: Any],
              let parameters = row["parameters"] as? [String],
              parameters.contains("structured_outputs") || parameters.contains("response_format") else { return false }
        let output = input.action == .peek ? 600 : input.generatedVisuals ? 16000 : input.mode == .ask ? 4000 : 10000
        // UTF-8 bytes conservatively upper-bound text input tokens. Search evidence
        // needs extra context; OpenRouter's existing web plugin supplies retrieval.
        let retrievalBudget = input.action.needsWeb ? (input.mode == .ask ? 16000 : 32000) : 0
        return (row["output"] as? Int ?? 0) >= output && (row["context"] as? Int ?? 0) >= bytes + output + retrievalBudget
    }
}
