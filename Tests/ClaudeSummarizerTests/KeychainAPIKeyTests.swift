@testable import ClaudeSummarizer
import Foundation
import Security
import Testing

/// Never the production `com.auricle.app.anthropic-api-key` identifier —
/// and unique per call, not just per file: Swift Testing runs these `@Test`
/// functions concurrently, and the real Keychain is process-wide shared
/// state, so two tests sharing one service identifier would race each
/// other's write/delete regardless of each test's own cleanup.
private func makeTestService() -> String {
    "com.auricle.app.anthropic-api-key.tests.\(UUID().uuidString)"
}

@Test func writeThenReadRoundTripsTheStoredKey() throws {
    let service = makeTestService()
    defer { try? KeychainAPIKey.delete(service: service) }

    try KeychainAPIKey.write("sk-ant-test", service: service)

    #expect(try KeychainAPIKey.read(service: service) == "sk-ant-test")
}

@Test func writeUpsertsAnExistingItemInPlaceWithoutRequiringADeleteFirst() throws {
    let service = makeTestService()
    defer { try? KeychainAPIKey.delete(service: service) }

    try KeychainAPIKey.write("sk-ant-first", service: service)
    try KeychainAPIKey.write("sk-ant-second", service: service)

    #expect(try KeychainAPIKey.read(service: service) == "sk-ant-second")
}

@Test func readThrowsNotFoundWhenNoItemExistsUnderTheService() throws {
    let service = makeTestService()

    #expect(throws: KeychainError.notFound) {
        try KeychainAPIKey.read(service: service)
    }
}

@Test func readThrowsUnexpectedStatusDecodeWhenTheStoredBytesAreNotValidUTF8() throws {
    let service = makeTestService()
    defer { try? KeychainAPIKey.delete(service: service) }
    // Bypasses `write(_:service:)` (which only ever stores valid UTF-8) to
    // plant bytes that fail the decode step specifically, under the exact
    // service/account identity `read(service:)` queries.
    let invalidUTF8 = Data([0xFF, 0xFE, 0xFD])
    let addQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: KeychainAPIKey.account,
        kSecValueData as String: invalidUTF8,
    ]
    let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
    #expect(addStatus == errSecSuccess)

    #expect(throws: KeychainError.unexpectedStatus(errSecDecode)) {
        try KeychainAPIKey.read(service: service)
    }
}
