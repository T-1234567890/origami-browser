import WebKit

/// WebKit owns HTTPS upgrades and HTTP fallback, including redirects and request
/// handling. Do not implement fallback by replaying failed requests ourselves.
enum HTTPSFirst {
    static func policy(enabled: Bool) -> WKWebpagePreferences.UpgradeToHTTPSPolicy {
        enabled ? .automaticFallbackToHTTP : .keepAsRequested
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
