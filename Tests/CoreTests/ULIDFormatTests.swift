@testable import Core
import Foundation
import Testing

private let crockfordAlphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

@Test func generatedULIDIs26CharCrockfordBase32() {
    let ulid = ULIDFormat.generate()

    #expect(ulid.count == 26)
    #expect(ulid.allSatisfy { crockfordAlphabet.contains($0) })
    #expect(ULIDFormat.isValid(ulid))
}

/// `MeetingID` strings are persisted, so the timestamp encoding is a wire
/// format. The 16 random characters cannot be pinned; the 10-character
/// timestamp prefix can. Expected prefixes are the 48-bit millisecond count
/// written as big-endian Crockford base32, worked out independently of the
/// library. Whole-second inputs keep the `Date` -> millisecond conversion exact.
@Test(arguments: [
    (seconds: 0.0, prefix: "0000000000"),
    (seconds: 1_469_918_176.0, prefix: "01ARYZ6RR0"),
    (seconds: 1_700_000_001.0, prefix: "01HF7YATZ8"),
])
func generatedULIDCarriesTheExactTimestampPrefixForAKnownTime(seconds: Double, prefix: String) {
    let ulid = ULIDFormat.generate(now: Date(timeIntervalSince1970: seconds))

    #expect(ulid.count == 26)
    #expect(ulid.allSatisfy { crockfordAlphabet.contains($0) })
    #expect(ulid.prefix(10) == prefix)
}

@Test func isValidRejectsWrongLengthAndDisallowedCharacters() {
    #expect(!ULIDFormat.isValid("TOOSHORT"))
    #expect(!ULIDFormat.isValid(String(repeating: "0", count: 27)))
    // 'I', 'L', 'O', 'U' are outside the Crockford alphabet.
    let disallowedCharacter = String(repeating: "0", count: 25) + "I"
    #expect(disallowedCharacter.count == 26)
    #expect(!ULIDFormat.isValid(disallowedCharacter))
}

@Test func isValidAcceptsLowercaseInput() {
    let ulid = ULIDFormat.generate()

    #expect(ULIDFormat.isValid(ulid.lowercased()))
}

/// `ß` uppercases to `SS`, so 13 of them are 26 UTF-8 bytes that expand into 26
/// alphabet characters once uppercased. The byte count alone cannot bound the
/// character count for non-ASCII input.
@Test func isValidRejectsNonASCIIThatUppercasesIntoTheAlphabet() {
    let sharpS = String(repeating: "\u{DF}", count: 13)

    #expect(sharpS.utf8.count == 26)
    #expect(sharpS.uppercased() == String(repeating: "S", count: 26))
    #expect(!ULIDFormat.isValid(sharpS))
    #expect(MeetingID(ulid: sharpS) == nil)
}

@Test func isValidRejectsANonASCIICharacterAmongValidOnes() {
    let ulid = ULIDFormat.generate()
    let withAccent = String(ulid.dropLast(2)) + "\u{E9}"

    #expect(withAccent.utf8.count == 26)
    #expect(!ULIDFormat.isValid(withAccent))
}

@Test func laterTimestampSortsAfterEarlierTimestamp() {
    let earlier = ULIDFormat.generate(now: Date(timeIntervalSince1970: 1_700_000_000))
    let later = ULIDFormat.generate(now: Date(timeIntervalSince1970: 1_700_000_100))

    #expect(earlier < later)
}

@Test func sameTimestampProducesSharedPrefixWithDistinctIDs() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let first = ULIDFormat.generate(now: now)
    let second = ULIDFormat.generate(now: now)

    #expect(first.prefix(10) == second.prefix(10))
    #expect(first != second)
}

@Test func pre1970TimestampDoesNotTrap() {
    let ulid = ULIDFormat.generate(now: Date(timeIntervalSince1970: -1))

    #expect(ulid.count == 26)
    #expect(ULIDFormat.isValid(ulid))
}
