import WebKit

/// WebKit performs upgrades, redirects and the warning/explicit HTTP fallback.
/// Never use automaticFallbackToHTTP: failed upgrades require user consent.
enum HTTPSFirst {
    static func policy(enabled: Bool) -> WKWebpagePreferences.UpgradeToHTTPSPolicy {
        enabled ? .userMediatedFallbackToHTTP : .keepAsRequested
    }
}

enum ConnectionSecurity: String {
    case local = "Local page", checking = "Checking connection", unverified = "Connection not verified", secure = "Encrypted connection"
    case mixed = "HTTPS with insecure content", insecure = "Unencrypted HTTP connection"
    var symbol: String {
        switch self {
        case .secure: "lock"
        case .insecure, .mixed, .unverified: "exclamationmark.shield"
        default: "info.circle"
        }
    }
    var warning: Bool { self == .insecure || self == .mixed || self == .unverified }
}
