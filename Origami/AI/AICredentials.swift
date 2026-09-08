import Foundation
import Security
import LocalAuthentication
import Observation

struct AICredentialStore {
    var service = "dev.origami.ai.providers"
    private func query(_ provider: AIProviderID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: provider.rawValue, kSecAttrSynchronizable as String: false]
    }
    func read(_ provider: AIProviderID) throws -> String {
        var q = query(provider); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data, let text = String(data: data, encoding: .utf8), !text.isEmpty else { throw AIError.credential }
        return text
    }
    func contains(_ provider: AIProviderID) -> Bool {
        var q = query(provider); q[kSecReturnAttributes as String] = true
        let context = LAContext(); context.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = context
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }
    func save(_ key: String, provider: AIProviderID) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count < 8192, !key.contains("\n"), !key.contains("\r") else { throw AIError.credential }
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        let result = SecItemUpdate(query(provider) as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            var q = query(provider); q[kSecValueData as String] = Data(key.utf8)
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw AIError.credential }
        } else if result != errSecSuccess { throw AIError.credential }
    }
    func forget(_ provider: AIProviderID) throws {
        let status = SecItemDelete(query(provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AIError.credential }
    }
}
@MainActor @Observable final class AISettings {
    static let shared = AISettings()
    private let defaults: UserDefaults
    var defaultsForFallback: UserDefaults { defaults }
    var provider: AIProviderID { didSet { defaults.set(provider.rawValue, forKey: "ai.provider"); revision += 1 } }
    var revision = 0
    private var openRouterCatalogRefreshedAt: Date?
    @ObservationIgnored private var catalogCache: CatalogSnapshot?
    private struct CatalogSnapshot {
        let provider: AIProviderID
        let revision: Int
        let models: [String]
        let names: [String: String]
        let free: Set<String>
    }
    private var catalog: CatalogSnapshot {
        if let cached = catalogCache, cached.provider == provider, cached.revision == revision { return cached }
        let snapshot = CatalogSnapshot(
            provider: provider, revision: revision,
            models: defaults.stringArray(forKey: "ai.catalog." + provider.rawValue) ?? [],
            names: defaults.dictionary(forKey: "ai.modelNames." + provider.rawValue) as? [String: String] ?? [:],
            free: Set(defaults.stringArray(forKey: "ai.freeModels." + provider.rawValue) ?? [])
        )
        catalogCache = snapshot
        return snapshot
    }
    init(defaults: UserDefaults = .standard) { self.defaults = defaults; provider = AIProviderID(rawValue: defaults.string(forKey: "ai.provider") ?? "") ?? .openRouter }
    func model(_ role: String, provider: AIProviderID? = nil) -> String { defaults.string(forKey: "ai.model.\((provider ?? self.provider).rawValue).\(role)") ?? "" }
    func setModel(_ value: String, role: String) { defaults.set(value.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "ai.model.\(provider.rawValue).\(role)"); revision += 1 }
    var verified: Bool { _ = revision; return defaults.bool(forKey: "ai.verified." + provider.rawValue) }
    var setupComplete: Bool { verified && !model("primary").isEmpty }
    var availableModels: [String] { catalog.models }
    func displayName(_ id: String) -> String {
        return catalog.names[id] ?? id.split(separator: "/").last.map(String.init) ?? id
    }
    func storeCatalog(_ rows: [[String: Any]]) {
        var names: [String: String] = [:]
        var jsonOnly: [String] = []
        for row in rows {
            guard let raw = row["id"] as? String ?? row["name"] as? String else { continue }
            let id = raw.hasPrefix("models/") ? String(raw.dropFirst(7)) : raw
            let capabilities = row["supported_parameters"] as? [String] ?? []
            if capabilities.contains("response_format") && !capabilities.contains("structured_outputs") { jsonOnly.append(id) }
            names[id] = row["displayName"] as? String ?? (provider == .openRouter ? row["name"] as? String : nil) ?? id
        }
        if provider == .openRouter {
            var capabilities: [String: [String: Any]] = [:]
            for row in rows {
                guard let id = row["id"] as? String else { continue }
                capabilities[id] = ["parameters": row["supported_parameters"] as? [String] ?? [], "context": row["context_length"] as? Int ?? 0, "output": (row["top_provider"] as? [String: Any])?["max_completion_tokens"] as? Int ?? 0]
            }
            defaults.set(capabilities, forKey: "ai.fallbackCapabilities." + provider.rawValue)
        }
        defaults.set(jsonOnly, forKey: "ai.jsonOnlyModels." + provider.rawValue)
        defaults.set(names, forKey: "ai.modelNames." + provider.rawValue)
        setCatalog(names.keys.sorted())
        if provider == .openRouter {
            setFreeModels(rows.filter(Self.isFreeOpenRouterModel).compactMap { $0["id"] as? String })
            openRouterCatalogRefreshedAt = Date()
        }
    }
    func isFreeModel(_ id: String) -> Bool {
        catalog.free.contains(id) || id.hasSuffix(":free") || id == "openrouter/free"
    }
    func refreshOpenRouterCatalog() async throws {
        guard provider == .openRouter else { return }
        if let refreshed = openRouterCatalogRefreshedAt, Date().timeIntervalSince(refreshed) < 300 { return }
        let network = AINetwork(); defer { network.stop() }
        let data = try await network.data(for: URLRequest(url: URL(string: "https://openrouter.ai/api/v1/models")!))
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard provider == .openRouter, let rows = root?["data"] as? [[String: Any]] else { return }
        storeCatalog(rows)
    }
    var generatedVisuals: Bool {
        get { _ = revision; return defaults.bool(forKey: "ai.generatedVisuals") }
        set { defaults.set(newValue, forKey: "ai.generatedVisuals"); revision += 1 }
    }
    func needsJSONMode(_ id: String) -> Bool {
        _ = revision
        return (defaults.stringArray(forKey: "ai.jsonOnlyModels." + provider.rawValue) ?? []).contains(id)
    }
    var searchEngine: String {
        get { _ = revision; return defaults.string(forKey: "ai.openRouter.searchEngine") ?? "auto" }
        set { defaults.set(newValue, forKey: "ai.openRouter.searchEngine"); revision += 1 }
    }
    var freeModels: [String] { _ = revision; return defaults.stringArray(forKey: "ai.freeModels." + provider.rawValue) ?? [] }
    var freeModelsOnly: Bool {
        get { _ = revision; return defaults.bool(forKey: "ai.freeModelsOnly") }
        set { defaults.set(newValue, forKey: "ai.freeModelsOnly"); revision += 1 }
    }
    func setFreeModels(_ values: [String]) { defaults.set(values, forKey: "ai.freeModels." + provider.rawValue); revision += 1 }
    static func isFreeOpenRouterModel(_ row: [String: Any]) -> Bool {
        guard let id = row["id"] as? String, id != "openrouter/auto",
              let pricing = row["pricing"] as? [String: Any],
              let prompt = pricing["prompt"].map({ String(describing: $0) }), let completion = pricing["completion"].map({ String(describing: $0) }),
              Decimal(string: prompt) == 0, Decimal(string: completion) == 0 else { return false }
        if let request = pricing["request"].map({ String(describing: $0) }), Decimal(string: request) != 0 { return false }
        return true
    }
    func setVerified(_ value: Bool) { defaults.set(value, forKey: "ai.verified." + provider.rawValue); revision += 1 }
    func setCatalog(_ values: [String]) { defaults.set(Array(values.prefix(2000)), forKey: "ai.catalog." + provider.rawValue); revision += 1 }
    func routedModel(action: AIAction, mode: AskMode) -> String {
        let role = action.lightweight ? "lightweight" : mode != .ask || [.credibility, .verify, .original, .primary, .compare].contains(action) ? "research" : "primary"
        let candidate = model(role); return candidate.isEmpty ? model("primary") : candidate
    }
}
