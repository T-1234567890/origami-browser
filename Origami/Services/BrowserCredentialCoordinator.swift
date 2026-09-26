import AppKit
import AuthenticationServices
import Observation
import Security

/// Browser-wide permission only. Website credentials and relying-party requests remain in WebKit.
@MainActor @Observable final class BrowserCredentialCoordinator {
    static let shared = BrowserCredentialCoordinator()
    struct Capabilities {
        let passkeys: Bool
        let browserCredentialManagement: Bool
        init(entitlements: [String: Any], adHoc: Bool) {
            passkeys = !adHoc && entitlements["com.apple.developer.web-browser.public-key-credential"] as? Bool == true
            browserCredentialManagement = !adHoc && entitlements["com.apple.developer.web-browser"] as? Bool == true
        }
        static func signedApplication() -> Self {
            var code: SecCode?
            var info: CFDictionary?
            var staticCode: SecStaticCode?
            guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
                  SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
                  SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
                  let values = info as? [String: Any] else {
                return Self(entitlements: [:], adHoc: true)
            }
            let flags = (values[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 2
            return Self(entitlements: values[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:],
                        adHoc: flags & 2 != 0)
        }
    }
    enum PasskeyState: Equatable { case unavailable, notDetermined, authorized, denied }
    // ASAuthorizationPasswordRequest carries neither a relying-party URL nor a returned credential scope.
    // Never send an app-associated password to an arbitrary website, even under the experimental flag.
    static let supportsWebsitePasswordRequests = false
    // Xcode 26.5: ASCredentialDataManager.save(password:for:title:anchor:) is unavailable on macOS.
    static let supportsWebsitePasswordSaving = false
    let capabilities: Capabilities
    private(set) var state: PasskeyState = .unavailable
    private(set) var requesting = false
    @ObservationIgnored private let manager = ASAuthorizationWebBrowserPublicKeyCredentialManager()
    init(capabilities: Capabilities = .signedApplication()) { self.capabilities = capabilities; refresh() }
    func refresh() {
        guard capabilities.passkeys else { state = .unavailable; return }
        switch manager.authorizationStateForPlatformCredentials {
        case .authorized: state = .authorized
        case .denied: state = .denied
        case .notDetermined: state = .notDetermined
        @unknown default: state = .unavailable
        }
    }
    static func shouldRequest(_ state: PasskeyState, requesting: Bool) -> Bool {
        state == .notDetermined && !requesting
    }
    /// Explicit native user action; never called by page scripts or automatically at launch.
    func requestPasskeyAccess() {
        refresh()
        #if DEBUG
        print("[Origami Passkeys] permission action invoked: capability=\(capabilities.passkeys) state=\(state) requesting=\(requesting)")
        #endif
        if state == .denied || state == .authorized {
            openSystemSettings()
            return
        }
        guard Self.shouldRequest(state, requesting: requesting) else { return }
        requesting = true
        // Leave menu tracking before asking macOS to present its permission UI.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.manager.requestAuthorizationForPublicKeyCredentials { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.requesting = false
                self.refresh()
                #if DEBUG
                print("[Origami Passkeys] permission request completed: returned=\(result.rawValue) refreshed=\(self.state)")
                #endif
            }
            }
        }
    }
    func openSystemSettings() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
}
