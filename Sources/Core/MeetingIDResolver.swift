import Foundation

/// `Core` can't depend on `State`/GRDB, so `MeetingIDResolver` takes an
/// injected data source instead of querying SQLite directly. `State`
/// provides the real GRDB-backed conformance; tests use a fake.
public protocol MeetingIDDataSource {
    func meetingIDs(matchingPrefix prefix: String) -> [MeetingID]
    /// The meeting currently in active capture (`meetings.state = 'recording'`).
    func currentMeetingID() -> MeetingID?
    /// The most recently created meeting (highest `created_at`).
    func lastMeetingID() -> MeetingID?
}

public enum MeetingIDResolution: Equatable {
    case resolved(MeetingID)
    case ambiguous([MeetingID])
    case notFound
}

/// Resolves the `<id>` argument every CLI verb (and the GUI, for internal
/// lookups) accepts: a full ULID, a unique prefix of at least 6 characters,
/// or the `current`/`last` keywords.
public struct MeetingIDResolver {
    /// Below this, a 6-char-alphabet ULID prefix is common enough to be
    /// ambiguous in practice; shorter inputs are rejected without a query.
    private static let minimumPrefixLength = 6

    private let dataSource: MeetingIDDataSource

    public init(dataSource: MeetingIDDataSource) {
        self.dataSource = dataSource
    }

    public func resolve(_ input: String) -> MeetingIDResolution {
        switch input {
        case "current":
            return dataSource.currentMeetingID().map(MeetingIDResolution.resolved) ?? .notFound
        case "last":
            return dataSource.lastMeetingID().map(MeetingIDResolution.resolved) ?? .notFound
        default:
            guard input.count >= Self.minimumPrefixLength else { return .notFound }
            let matches = dataSource.meetingIDs(matchingPrefix: input.uppercased())
            switch matches.count {
            case 0:
                return .notFound
            case 1:
                return .resolved(matches[0])
            default:
                return .ambiguous(matches)
            }
        }
    }
}
