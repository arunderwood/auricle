import Foundation
@testable import GoogleCalendarSource
import Testing

/// Never the production `com.auricle.app.google-oauth-refresh-token`
/// identifier, and unique per call: Swift Testing runs tests concurrently
/// against one process-wide Keychain, so a shared identifier would let two
/// tests race each other's write and delete.
func makeTestKeychainService() -> String {
    "com.auricle.app.google-oauth-refresh-token.tests.\(UUID().uuidString)"
}

@Test func refreshTokenStoreProductionServiceIsTheDocumentedIdentifier() {
    #expect(GoogleRefreshTokenStore.productionService == "com.auricle.app.google-oauth-refresh-token")
}

@Test func refreshTokenStoreWriteThenReadRoundTrips() throws {
    let service = makeTestKeychainService()
    defer { try? GoogleRefreshTokenStore.delete(service: service) }

    try GoogleRefreshTokenStore.write("1//refresh-token-value", service: service)

    #expect(try GoogleRefreshTokenStore.read(service: service) == "1//refresh-token-value")
}

@Test func refreshTokenStoreWriteUpsertsAnExistingItem() throws {
    let service = makeTestKeychainService()
    defer { try? GoogleRefreshTokenStore.delete(service: service) }

    try GoogleRefreshTokenStore.write("first", service: service)
    try GoogleRefreshTokenStore.write("second", service: service)

    #expect(try GoogleRefreshTokenStore.read(service: service) == "second")
}

@Test func refreshTokenStoreReadThrowsNotFoundWhenNothingIsStored() {
    let service = makeTestKeychainService()

    #expect(throws: GoogleRefreshTokenStoreError.notFound) {
        try GoogleRefreshTokenStore.read(service: service)
    }
}

@Test func refreshTokenStoreDeleteRemovesTheItemAndIsIdempotent() throws {
    let service = makeTestKeychainService()
    try GoogleRefreshTokenStore.write("value", service: service)

    try GoogleRefreshTokenStore.delete(service: service)
    try GoogleRefreshTokenStore.delete(service: service)

    #expect(throws: GoogleRefreshTokenStoreError.notFound) {
        try GoogleRefreshTokenStore.read(service: service)
    }
}
