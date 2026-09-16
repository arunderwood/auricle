import Foundation

/// A meeting's identity: a 26-character Crockford base32 ULID wrapped in a
/// dedicated type so the compiler rejects a raw `String` substituted by
/// accident (AR-PAT-7).
public struct MeetingID: Hashable, Sendable {
    public let rawValue: String

    /// Wraps an existing ULID string, validating its shape. Returns `nil` if
    /// `ulid` is not a well-formed 26-character Crockford base32 ULID.
    public init?(ulid: String) {
        guard ULID.isValid(ulid) else { return nil }
        rawValue = ulid.uppercased()
    }

    /// Generates a fresh, timestamp-ordered `MeetingID`.
    public static func generate() -> MeetingID {
        // ULID.generate() always produces a well-formed 26-char ULID, so the
        // validating initializer can't fail here.
        MeetingID(ulid: ULID.generate())!
    }
}

extension MeetingID: CustomStringConvertible {
    public var description: String { rawValue }
}
