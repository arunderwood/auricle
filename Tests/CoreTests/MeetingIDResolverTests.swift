@testable import Core
import Testing

private final class FakeMeetingIDDataSource: MeetingIDDataSource {
    var pool: [MeetingID] = []
    var current: MeetingID?
    var last: MeetingID?

    func meetingIDs(matchingPrefix prefix: String) -> [MeetingID] {
        pool.filter { $0.rawValue.hasPrefix(prefix) }
    }

    func currentMeetingID() -> MeetingID? {
        current
    }

    func lastMeetingID() -> MeetingID? {
        last
    }
}

// Fixed, valid (Crockford-alphabet, 26-char) fixture IDs. `idA` and `idB`
// deliberately share a 6-char prefix to exercise the ambiguous-prefix case.
private let idA = MeetingID(ulid: "01ARZ3NDEKTSV4RRFFQ69G5FAV")!
private let idB = MeetingID(ulid: "01ARZ3AAAAAAAAAAAAAAAAAAAA")!
private let idC = MeetingID(ulid: "01BRAND00000000000000000WN")!

@Test func resolvesFullULID() {
    let dataSource = FakeMeetingIDDataSource()
    dataSource.pool = [idA, idC]
    let resolver = MeetingIDResolver(dataSource: dataSource)

    #expect(resolver.resolve(idA.rawValue) == .resolved(idA))
}

@Test func resolvesLowercaseFullULID() {
    let dataSource = FakeMeetingIDDataSource()
    dataSource.pool = [idA, idC]
    let resolver = MeetingIDResolver(dataSource: dataSource)

    #expect(resolver.resolve(idA.rawValue.lowercased()) == .resolved(idA))
}

@Test func resolvesUniquePrefix() {
    let dataSource = FakeMeetingIDDataSource()
    dataSource.pool = [idA, idC]
    let resolver = MeetingIDResolver(dataSource: dataSource)

    #expect(resolver.resolve("01BRAN") == .resolved(idC))
}

@Test func resolvesCurrent() {
    let dataSource = FakeMeetingIDDataSource()
    dataSource.current = idA
    let resolver = MeetingIDResolver(dataSource: dataSource)

    #expect(resolver.resolve("current") == .resolved(idA))
}

@Test func currentWithNoActiveCaptureIsNotFound() {
    let dataSource = FakeMeetingIDDataSource()
    dataSource.current = nil
    let resolver = MeetingIDResolver(dataSource: dataSource)

    #expect(resolver.resolve("current") == .notFound)
}

@Test func resolvesLast() {
    let dataSource = FakeMeetingIDDataSource()
    dataSource.last = idB
    let resolver = MeetingIDResolver(dataSource: dataSource)

    #expect(resolver.resolve("last") == .resolved(idB))
}

@Test func ambiguousPrefixReturnsAllMatches() {
    let dataSource = FakeMeetingIDDataSource()
    dataSource.pool = [idA, idB, idC]
    let resolver = MeetingIDResolver(dataSource: dataSource)

    let result = resolver.resolve("01ARZ3")
    guard case let .ambiguous(matches) = result else {
        Issue.record("Expected .ambiguous, got \(result)")
        return
    }
    #expect(Set(matches) == Set([idA, idB]))
}

@Test func prefixShorterThanSixCharsIsNotFoundWithoutQuerying() {
    let dataSource = FakeMeetingIDDataSource()
    dataSource.pool = [idA, idB, idC]
    let resolver = MeetingIDResolver(dataSource: dataSource)

    #expect(resolver.resolve("01ARZ") == .notFound)
}

/// `ß` uppercases to `SS`: without the ASCII check, six of them pass the
/// length gate and reach the data source as twelve `S`s.
@Test func aNonASCIIPrefixIsNotFoundAndNeverReachesTheDataSource() throws {
    let dataSource = FakeMeetingIDDataSource()
    dataSource.pool = try [#require(MeetingID(ulid: String(repeating: "S", count: 26)))]
    let resolver = MeetingIDResolver(dataSource: dataSource)

    #expect(resolver.resolve(String(repeating: "\u{DF}", count: 6)) == .notFound)
    #expect(resolver.resolve(String(repeating: "\u{DF}", count: 13)) == .notFound)
}
