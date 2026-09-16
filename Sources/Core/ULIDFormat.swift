import Foundation
import ULID

/// Crockford base32 ULID generation. A ULID is 26 characters: a 48-bit
/// millisecond timestamp encoded as the first 10 characters — so lexical
/// string order matches creation order — followed by 16 characters of random
/// entropy. `generate()` wraps `yaslab/ULID.swift`'s `ULID` type — named
/// `ULIDFormat` here (not `ULID`) so it doesn't collide with that module's
/// own top-level `ULID` type name.
public enum ULIDFormat {
    /// Crockford's base32 alphabet: excludes `I`, `L`, `O`, `U` to avoid
    /// visual confusion with `1`, `1`, `0`, and profanity respectively.
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let alphabetSet = Set(alphabet)

    /// Generates a new 26-character ULID string. `now` defaults to the
    /// current time; tests pass an explicit value to make the timestamp
    /// ordering property deterministic.
    ///
    /// `now` is clamped to a non-negative millisecond offset before reaching
    /// the library: its own `Double -> UInt64` conversion traps (does not
    /// clamp) on a pre-1970 timestamp.
    public static func generate(now: Date = Date()) -> String {
        let millis = now.timeIntervalSince1970 * 1000
        let clampedMillis = min(max(0, millis), Double(UInt64.max))
        let clampedNow = Date(timeIntervalSince1970: clampedMillis / 1000)
        return ULID(timestamp: clampedNow).ulidString
    }

    /// Whether `string` is a well-formed 26-character Crockford base32 ULID.
    ///
    /// Deliberately stricter than the `ULID.swift` library's own decoder,
    /// which Crockford-alias-folds (`I`/`L` -> `1`, `O` -> `0`) and would
    /// accept strings this type has always rejected — that leniency is a
    /// consciously separate, not-yet-made decision, not a side effect of
    /// this type's backing implementation.
    public static func isValid(_ string: String) -> Bool {
        guard string.utf8.count == 26 else { return false }
        return string.uppercased().allSatisfy { alphabetSet.contains($0) }
    }
}
