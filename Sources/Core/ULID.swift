import Foundation

/// Crockford base32 ULID generation, Foundation-only (no third-party ULID
/// package). A ULID is 26 characters: a 48-bit millisecond timestamp encoded
/// as the first 10 characters — so lexical string order matches creation
/// order — followed by 16 characters of random entropy.
public enum ULID {
    /// Crockford's base32 alphabet: excludes `I`, `L`, `O`, `U` to avoid
    /// visual confusion with `1`, `1`, `0`, and profanity respectively.
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let alphabetSet = Set(alphabet)

    /// Generates a new 26-character ULID string. `now` defaults to the
    /// current time; tests pass an explicit value to make the timestamp
    /// ordering property deterministic.
    public static func generate(now: Date = Date()) -> String {
        let millis = now.timeIntervalSince1970 * 1000
        let clamped = min(max(0, millis), Double(UInt64.max))
        return encodeTimestamp(UInt64(clamped)) + encodeRandomness()
    }

    /// Whether `string` is a well-formed 26-character Crockford base32 ULID.
    public static func isValid(_ string: String) -> Bool {
        guard string.utf8.count == 26 else { return false }
        return string.uppercased().allSatisfy { alphabetSet.contains($0) }
    }

    /// 48 bits of timestamp, big-endian, 5 bits per character -> 10 characters.
    private static func encodeTimestamp(_ millis: UInt64) -> String {
        var characters = [Character](repeating: "0", count: 10)
        var value = millis
        for index in stride(from: 9, through: 0, by: -1) {
            characters[index] = alphabet[Int(value & 0x1F)]
            value >>= 5
        }
        return String(characters)
    }

    /// 80 bits of randomness, 5 bits per character -> 16 characters.
    private static func encodeRandomness() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<10).map { _ in UInt8.random(in: 0...255, using: &generator) }
        return encodeBase32(bytes)
    }

    private static func encodeBase32(_ bytes: [UInt8]) -> String {
        var bitBuffer: UInt64 = 0
        var bitCount = 0
        var characters: [Character] = []
        for byte in bytes {
            bitBuffer = (bitBuffer << 8) | UInt64(byte)
            bitCount += 8
            while bitCount >= 5 {
                bitCount -= 5
                characters.append(alphabet[Int((bitBuffer >> UInt64(bitCount)) & 0x1F)])
            }
        }
        if bitCount > 0 {
            characters.append(alphabet[Int((bitBuffer << UInt64(5 - bitCount)) & 0x1F)])
        }
        return String(characters)
    }
}
