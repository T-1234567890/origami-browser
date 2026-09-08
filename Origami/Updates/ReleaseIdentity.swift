import Foundation

enum ReleaseStage: String, Codable, CaseIterable { case stable, beta }

/// Shared by the application and the release CLI. Never derive identity from update preferences.
struct ReleaseIdentity: Encodable, Equatable {
    let tag: String
    let marketingVersion: String
    let buildNumber: Int
    let stage: ReleaseStage
    let prereleaseNumber: Int?

    enum InvalidRelease: Error { case tag, build }
    init(tag: String, buildNumber: Int) throws {
        guard buildNumber > 0 else { throw InvalidRelease.build }
        let pattern = #"^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-(beta)\.([1-9][0-9]*))?$"#
        let expression = try NSRegularExpression(pattern: pattern)
        let range = NSRange(tag.startIndex..., in: tag)
        guard let match = expression.firstMatch(in: tag, range: range), match.range == range else { throw InvalidRelease.tag }
        func part(_ index: Int) -> String? { Range(match.range(at: index), in: tag).map { String(tag[$0]) } }
        guard (1...3).allSatisfy({ Int(part($0) ?? "") != nil }) else { throw InvalidRelease.tag }
        let number = part(5).flatMap(Int.init)
        guard part(5) == nil || number != nil else { throw InvalidRelease.tag }
        self.tag = tag; self.buildNumber = buildNumber
        marketingVersion = (1...3).compactMap(part).joined(separator: ".")
        stage = part(4).flatMap(ReleaseStage.init(rawValue:)) ?? .stable
        prereleaseNumber = number
    }
    var displayVersion: String {
        let parts = marketingVersion.split(separator: ".")
        let short = parts.last == "0" ? parts.dropLast().joined(separator: ".") : marketingVersion
        let suffix = stage == .stable ? "" : " Beta \(prereleaseNumber!)"
        return "Origami \(short)\(suffix)"
    }
    var channel: String? { stage == .stable ? nil : "beta" }
    var assetName: String { "Origami-\(tag.dropFirst()).zip" }
    static func from(info: [String: Any]) -> ReleaseIdentity? {
        guard let tag = info["OrigamiReleaseTag"] as? String,
              let build = Int(info["CFBundleVersion"] as? String ?? ""),
              let identity = try? Self(tag: tag, buildNumber: build),
              info["CFBundleShortVersionString"] as? String == identity.marketingVersion,
              info["OrigamiReleaseStage"] as? String == identity.stage.rawValue,
              info["OrigamiPrereleaseNumber"] as? String == identity.prereleaseNumber.map(String.init) ?? "" else { return nil }
        return identity
    }
}

enum UpdateChannel: String, CaseIterable, Identifiable {
    case stable, beta
    var id: Self { self }
    var title: String { self == .stable ? "Stable" : "Beta" }
    var sparkleChannels: Set<String> { self == .beta ? ["beta"] : [] }
    func accepts(_ stage: ReleaseStage) -> Bool { stage == .stable || self == .beta }
}

struct UpdatePreferences {
    let defaults: UserDefaults
    var channel: UpdateChannel {
        get { UpdateChannel(rawValue: defaults.string(forKey: "updates.channel") ?? "") ?? .stable }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "updates.channel") }
    }
}

struct UpdateConfiguration {
    let feed: URL
    let publicKey: String
    init?(info: [String: Any]) {
        guard let raw = info["SUFeedURL"] as? String,
              let url = URL(string: raw), url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              !raw.contains("$("),
              let key = info["SUPublicEDKey"] as? String,
              let bytes = Data(base64Encoded: key), bytes.count == 32 else { return nil }
        feed = url; publicKey = key
    }
}
