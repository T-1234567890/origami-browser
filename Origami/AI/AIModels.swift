import Foundation

enum AIProviderID: String, Codable, CaseIterable, Identifiable {
    case openRouter = "OpenRouter", gemini = "Gemini", openAI = "OpenAI", xAI = "xAI"
    var id: Self { self }
    var endpoint: URL {
        switch self {
        case .openRouter: URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        case .openAI: URL(string: "https://api.openai.com/v1/responses")!
        case .xAI: URL(string: "https://api.x.ai/v1/responses")!
        case .gemini: URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!
        }
    }
}
enum AskMode: String, Codable, CaseIterable { case ask = "Ask", research = "Research", reference = "Reference" }
enum AIAction: String, Codable, CaseIterable, Identifiable {
    case web = "Ask the Web", page = "Ask This Page", summarize = "Summarize Page", selection = "Ask About Selection", explain = "Explain Selection", compare = "Compare Tabs", peek = "Peek Summary", credibility = "Evaluate Credibility", verify = "Verify with the Web", original = "Find Original Source", primary = "Find Primary Source"
    var id: Self { self }
    var needsWeb: Bool { [.web, .credibility, .verify, .original, .primary].contains(self) }
    var lightweight: Bool { self == .peek || self == .explain || self == .credibility }
}
enum CredibilityState: String, Codable, CaseIterable {
    case highlyCredible = "Highly Credible", credible = "Credible", caution = "Use with Caution", questionable = "Questionable", unreliable = "Unreliable", unknown = "Unable to Assess"
}
enum VerificationState: String, Codable, CaseIterable { case supported = "Supported", mixed = "Mixed / Disputed", unsupported = "Unsupported", unknown = "Unable to Verify" }
struct AISource: Codable, Identifiable, Equatable {
    var id: String { url }
    var url: String
    var title: String
    var provenance: String // Provider citation, or explicitly supplied page; never inferred from prose.
    static func safeURL(_ value: String) -> URL? {
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }
}
struct AICitation: Codable, Equatable {
    var sourceURL: String
    var excerpt: String
    var startIndex: Int?
    var endIndex: Int?
    var groundingChunkIndex: Int?
    var offsetUnit: String?
}
struct AIBlock: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case heading, prose, points, steps, code, table, callout }
    var id = UUID()
    var kind: Kind
    var text: String
    var rows: [[String]] = []
    var sourceURLs: [String] = []
}
struct AIPageContext: Codable, Equatable {
    var title: String
    var url: String
    var text: String
}
struct AISearchEvent: Codable, Identifiable {
    var id = UUID()
    var profileID: UUID?
    var query: String
    var mode: AskMode
    var action: AIAction
    var date = Date()
    var provider: AIProviderID
    var model: String
    var status = "Preparing"
    var answerV1: OrigamiAnswerV1?
    var generatedVisuals: Bool?
    var providerSources: [AISource]?
    var blocks: [AIBlock] = []
    var sources: [AISource] = []
    var citations: [AICitation] = []
    var credibility: CredibilityState?
    var verification: VerificationState?
    var usage: String?
    var markdown: String?
    var searchSuggestions: String?
    var explorations: [AISearchEvent]?
    var versions: [AISearchEvent]?
    var needsSetup: Bool?
    var fallbackDisclosure: String?
}
struct AIRequest {
    var isPrivate = false
    var query: String
    var mode: AskMode
    var action: AIAction
    var contexts: [AIPageContext]
    var model: String
    var priorExploration: String? = nil
    var searchEngine: String = "auto"
    var generatedVisuals: Bool = false
    var jsonOnlyFallback = false
    var prompt: String { userPayload }
    var systemInstruction: String { AnswerSystemPrompt.make(mode: mode, action: action, visuals: generatedVisuals) }
    var userPayload: String {
        struct Query: Encodable { let query: String; let mode: String; let action: String }
        return String(data: (try? JSONEncoder().encode(Query(query: query, mode: mode.rawValue.lowercased(), action: action.rawValue))) ?? Data(), encoding: .utf8) ?? "{}"
    }
    var evidencePayload: String {
        struct Evidence: Encodable { let label = "UNTRUSTED_EVIDENCE"; let pages: [AIPageContext]; let priorExploration: String? }
        return String(data: (try? JSONEncoder().encode(Evidence(pages: contexts, priorExploration: priorExploration))) ?? Data(), encoding: .utf8) ?? "{}"
    }

}
struct AIProviderResult {
    var answeredModel: String? = nil
    var fallbackDisclosure: String? = nil
    var text: String
    var sources: [AISource]
    var citations: [AICitation]
    var searched: Bool
    var usage: String?
    var suggestions: String?
}
enum AIError: LocalizedError {
    case featureDisabled
    case unavailable(Int), nonRetryable(Int), noCompatibleFallback
    case credential, model, response, invalidJSON, answerSchema, truncated, http(Int), tooLarge, noSelection, noPage, cancelled
    var requiresSetup: Bool { switch self { case .credential, .model, .http(401), .http(403), .nonRetryable(401), .nonRetryable(403): true; default: false } }
    var errorDescription: String? {
        switch self {
        case .featureDisabled: "AI Peek and credibility assessment are temporarily disabled."
        case .unavailable: "The selected model is temporarily unavailable. Try again later."
        case .nonRetryable(let status): "Provider request failed (HTTP \(status)). Check your provider settings and request requirements."
        case .noCompatibleFallback: "The selected model is temporarily unavailable. No compatible fallback model is configured."
        case .credential: "Connect a provider in Settings → AI."
        case .model: "Choose a compatible model in Settings → AI."
        case .truncated: "The provider stopped before completing the answer. Retry with a smaller visual or a different model."
        case .invalidJSON: "The model returned incomplete or invalid JSON. Retry, or choose a model with structured-output support."
        case .answerSchema: "The model’s answer did not match the required answer format. Retry, or choose a model with structured-output support."
        case .response: "The provider did not return a usable answer. Try another model or request."
        case .http(let status): "Provider request failed (HTTP \(status)). Check your credential, model access, quota and web-search support."
        case .tooLarge: "The provider response exceeded the size limit. Try a shorter request."
        case .noSelection: "Select text on the webpage first."
        case .noPage: "Choose a loaded webpage. Internal pages are not sent to AI."
        case .cancelled: "Cancelled."
        }
    }
}
