import Foundation
import Security

/// Typed failures from `KeychainAPIKey`. `.unexpectedStatus` carries the raw
/// `OSStatus` so a Keychain failure this table doesn't anticipate is still
/// diagnosable rather than collapsed into one opaque case.
public enum KeychainError: Error, Sendable, Equatable {
    case notFound
    case unexpectedStatus(OSStatus)
}

/// Reads and writes the Anthropic API key from the macOS Keychain
/// (`kSecClassGenericPassword`, NFR-S1). Nothing in this type or any caller
/// keeps the key in memory beyond a single use: `AnthropicHTTPClient`
/// calls `read()` once per `send(_:)` call (covering that call's own
/// retries) and never stores the result as a property.
///
/// The public `read()`/`write(_:)` pair always targets the one production
/// service identifier. The service-parameterized overloads below exist only
/// so `KeychainAPIKeyTests` can exercise a real Keychain round-trip against
/// a throwaway identifier instead of ever touching the maintainer's real
/// stored key.
public enum KeychainAPIKey {
    static let productionService = "com.auricle.app.anthropic-api-key"

    /// Every item this type stores is a single API key per service, so one
    /// fixed account name is enough to make each item addressable —
    /// there's no second axis (multiple keys per service) to disambiguate.
    /// Not `private`: `KeychainAPIKeyTests` needs it to plant a raw item
    /// with `SecItemAdd` directly, under the exact identity `read(service:)`
    /// queries, to exercise the decode-failure path `write(_:service:)`
    /// can't reach (it only ever stores valid UTF-8).
    static let account = "api-key"

    public static func read() throws -> String {
        try read(service: productionService)
    }

    public static func write(_ key: String) throws {
        try write(key, service: productionService)
    }

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

        guard status != errSecItemNotFound else { throw KeychainError.notFound }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
            // The Keychain call itself succeeded; it's the retrieved bytes
            // that don't decode. Reusing `status` here would misreport this
            // as "unexpected status: success".
            throw KeychainError.unexpectedStatus(errSecDecode)
        }
        return key
    }

    /// Upserts: updates the existing item in place when one is already
    /// stored under `service`, adds a new one otherwise. Rotating the key
    /// must not require deleting the old one first.
    static func write(_ key: String, service: String) throws {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(key.utf8)

        let updateStatus = SecItemUpdate(identity as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard updateStatus != errSecSuccess else { return }

        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        var addQuery = identity
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
    }

    /// Test-only cleanup hook: `KeychainAPIKeyTests` must never leave a
    /// stray item behind under its throwaway service identifier, but
    /// production code has no legitimate reason to ever delete the
    /// maintainer's stored key, so this stays unexposed rather than joining
    /// `read`/`write` as a public operation.
    static func delete(service: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
