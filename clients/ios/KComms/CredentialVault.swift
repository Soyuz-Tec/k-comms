import Foundation
import Security

protocol CredentialVault: Sendable {
    func load() throws -> CredentialEnvelope?
    func save(_ credential: CredentialEnvelope) throws
    func clear() throws
}

/// A single non-synchronizing, device-bound item; no token enters UserDefaults or logs.
struct KeychainCredentialVault: CredentialVault {
    private let service = "com.soyuztec.kcomms.member-session.v1"
    private let account = "current-member"
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
    func load() throws -> CredentialEnvelope? {
        var lookup = query; lookup[kSecReturnData as String] = true; lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw VaultError(status: status) }
        do { return try Wire.decoder().decode(CredentialEnvelope.self, from: data) }
        catch { try clear(); throw error }
    }
    func save(_ credential: CredentialEnvelope) throws {
        let data = try Wire.encoder().encode(credential)
        let update: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item.merge(update) { _, new in new }; status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw VaultError(status: status) }
    }
    func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultError(status: status) }
    }
    private struct VaultError: Error { let status: OSStatus }
}
