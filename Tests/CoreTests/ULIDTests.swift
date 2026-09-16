import Foundation
import Testing
@testable import Core

private let crockfordAlphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

@Test func generatedULIDIs26CharCrockfordBase32() {
    let ulid = ULID.generate()

    #expect(ulid.count == 26)
    #expect(ulid.allSatisfy { crockfordAlphabet.contains($0) })
    #expect(ULID.isValid(ulid))
}

@Test func isValidRejectsWrongLengthAndDisallowedCharacters() {
    #expect(!ULID.isValid("TOOSHORT"))
    #expect(!ULID.isValid(String(repeating: "0", count: 27)))
    // 'I', 'L', 'O', 'U' are outside the Crockford alphabet.
    let disallowedCharacter = String(repeating: "0", count: 25) + "I"
    #expect(disallowedCharacter.count == 26)
    #expect(!ULID.isValid(disallowedCharacter))
}

@Test func isValidAcceptsLowercaseInput() {
    let ulid = ULID.generate()

    #expect(ULID.isValid(ulid.lowercased()))
}

@Test func laterTimestampSortsAfterEarlierTimestamp() {
    let earlier = ULID.generate(now: Date(timeIntervalSince1970: 1_700_000_000))
    let later = ULID.generate(now: Date(timeIntervalSince1970: 1_700_000_100))

    #expect(earlier < later)
}

@Test func sameTimestampProducesSharedPrefixWithDistinctIDs() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let first = ULID.generate(now: now)
    let second = ULID.generate(now: now)

    #expect(first.prefix(10) == second.prefix(10))
    #expect(first != second)
}
