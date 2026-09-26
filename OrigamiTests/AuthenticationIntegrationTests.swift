import Foundation
import Security
import Testing
@testable import Origami

@MainActor struct AuthenticationIntegrationTests {
    @Test func signedCapabilitiesAreDistinctAndAdHocFailsClosed() {
        let passkey = ["com.apple.developer.web-browser.public-key-credential": true]
        let supported = BrowserCredentialCoordinator.Capabilities(entitlements: passkey, adHoc: false)
        #expect(supported.passkeys)
        #expect(!supported.browserCredentialManagement)
        #expect(!BrowserCredentialCoordinator.Capabilities(entitlements: passkey, adHoc: true).passkeys)
        #expect(!BrowserCredentialCoordinator.Capabilities(entitlements: [:], adHoc: false).passkeys)
        #expect(!BrowserCredentialCoordinator.supportsWebsitePasswordRequests)
        #expect(!BrowserCredentialCoordinator.supportsWebsitePasswordSaving)
    }
    @Test func permissionRequestsAreExplicitAndNeverRepeatAfterDecision() {
        #expect(BrowserCredentialCoordinator.shouldRequest(.notDetermined, requesting: false))
        for state in [BrowserCredentialCoordinator.PasskeyState.authorized, .denied, .unavailable] {
            #expect(!BrowserCredentialCoordinator.shouldRequest(state, requesting: false))
        }
        #expect(!BrowserCredentialCoordinator.shouldRequest(.notDetermined, requesting: true))
    }
    @Test func keychainCRUDPreservesIdentityAndHandlesConcurrentInsertion() throws {
        // In-memory Security boundary: no dependency on CI's login keychain or user accounts.
        var value: Data?
        var updates = 0
        var store = KeychainStore(service: "test.fixture")
        store.operations = .init(copy: { query, result in
            let q = query as! [String: Any]
            #expect(q[kSecAttrService as String] as? String == "test.fixture")
            guard let value else { return errSecItemNotFound }
            result?.pointee = value as CFData
            return errSecSuccess
        }, add: { query, _ in
            value = (query as! [String: Any])[kSecValueData as String] as? Data
            return errSecSuccess
        }, update: { _, attributes in
            updates += 1
            guard value != nil else { return errSecItemNotFound }
            value = (attributes as! [String: Any])[kSecValueData as String] as? Data
            return errSecSuccess
        }, delete: { _ in value = nil; return errSecSuccess })
        #expect(try !store.contains("fixture"))
        try store.save(Data("first".utf8), account: "fixture")
        #expect(try store.read("fixture") == Data("first".utf8))
        try store.save(Data("second".utf8), account: "fixture")
        #expect(try store.read("fixture") == Data("second".utf8))
        try store.delete("fixture")
        #expect(try !store.contains("fixture"))
        store.operations.add = { _, _ in value = Data(); return errSecDuplicateItem }
        try store.save(Data("race".utf8), account: "fixture")
        #expect(try store.read("fixture") == Data("race".utf8))
        #expect(updates == 4)
        store.operations.delete = { _ in errSecItemNotFound }
        try store.delete("fixture")
        store.operations.update = { _, _ in errSecAuthFailed }
        #expect(throws: KeychainStore.Failure(status: errSecAuthFailed)) {
            try store.save(Data(), account: "fixture")
        }
    }
}
