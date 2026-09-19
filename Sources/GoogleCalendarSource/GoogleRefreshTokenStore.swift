import Foundation
import Security

enum GoogleRefreshTokenStoreError: Error, Sendable, Equatable {
    case notFound
    case unexpectedStatus(OSStatus)
}

/// The Google OAuth refresh token's home in the macOS Keychain
/// (`kSecClassGenericPassword`, NFR-S1). Callers read it at the moment a
/// refresh needs it and never keep it in a property.
///
/// Every operation takes the Keychain service explicitly.
/// `GoogleCalendarSource` passes `productionService`; tests pass a throwaway
/// identifier so they can round-trip a real Keychain item without touching the
/// maintainer's stored token.
enum GoogleRefreshTokenStore {
    static let productionService = "com.auricle.app.google-oauth-refresh-token"

    /// One token per service, so a single fixed account name addresses it.
    static let account = "refresh-token"

    static func read(service: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status != errSecItemNotFound else { throw GoogleRefreshTokenStoreError.notFound }
        guard status == errSecSuccess else { throw GoogleRefreshTokenStoreError.unexpectedStatus(status) }
        guard let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
            throw GoogleRefreshTokenStoreError.unexpectedStatus(errSecDecode)
        }
        return token
    }

    /// Updates the item in place when one exists under `service` and adds one
    /// otherwise, so re-authorizing over a revoked token needs no delete first.
    static func write(_ token: String, service: String) throws {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(token.utf8)

        let updateStatus = SecItemUpdate(identity as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard updateStatus != errSecSuccess else { return }

        guard updateStatus == errSecItemNotFound else {
            throw GoogleRefreshTokenStoreError.unexpectedStatus(updateStatus)
        }

        var addQuery = identity
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw GoogleRefreshTokenStoreError.unexpectedStatus(addStatus) }
    }

    /// Only the tests' throwaway services are ever deleted; nothing in
    /// production removes the maintainer's stored token.
    static func delete(service: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GoogleRefreshTokenStoreError.unexpectedStatus(status)
        }
    }
}
