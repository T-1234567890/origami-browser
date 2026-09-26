import Foundation
import LocalAuthentication
import Security

/// App-owned secrets only. This does not access Apple Passwords or other apps' items.
struct KeychainStore {
    struct Failure: Error, Equatable { let status: OSStatus }
    struct Operations {
        var copy: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemCopyMatching
        var add: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemAdd
        var update: (CFDictionary, CFDictionary) -> OSStatus = SecItemUpdate
        var delete: (CFDictionary) -> OSStatus = SecItemDelete
    }
    let service: String
    var operations = Operations()
    private func query(_ account: String) -> [String: Any] {
        // Preserve existing AI item identity and keychain backend; no new sharing groups.
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
    func read(_ account: String) throws -> Data {
        var q = query(account)
        q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        try check(operations.copy(q as CFDictionary, &value))
        guard let data = value as? Data else { throw Failure(status: errSecDecode) }
        return data
    }
    func contains(_ account: String) throws -> Bool {
        var q = query(account)
        q[kSecReturnAttributes as String] = true
        let context = LAContext(); context.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = context
        let status = operations.copy(q as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        try check(status); return true
    }
    func add(_ data: Data, account: String) throws {
        var q = query(account); q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        try check(operations.add(q as CFDictionary, nil))
    }
    func update(_ data: Data, account: String) throws {
        try check(operations.update(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary))
    }
    func save(_ data: Data, account: String) throws {
        do { try update(data, account: account) }
        catch let error as Failure where error.status == errSecItemNotFound {
            do { try add(data, account: account) }
            catch let error as Failure where error.status == errSecDuplicateItem {
                // A concurrent writer inserted after our update. Keep a single item.
                try update(data, account: account)
            }
        }
    }
    func delete(_ account: String) throws {
        let status = operations.delete(query(account) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw Failure(status: status) }
    }
}
