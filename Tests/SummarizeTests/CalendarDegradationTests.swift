import CalendarInterface
@testable import Core
import Foundation
import Orchestrator
import Persist
import State
@testable import Summarize
import SummarizerInterface
import Testing

// MARK: - Event fixtures

private let eventStart = Date(timeIntervalSince1970: 1_777_377_600) // 2026-04-28T12:00:00Z
private let eventEnd = eventStart.addingTimeInterval(3600)
private let privateEmail = "ada.private@example.com"

private func makeEvent(
    title: String = "Weekly Sync",
    attendees: [CalendarAttendee] = [
        CalendarAttendee(email: privateEmail, displayName: "Ada Lovelace", isSelf: true),
        CalendarAttendee(email: "ben.private@example.com", displayName: "Ben Ng", isSelf: false),
    ],
) -> CalendarEvent {
    CalendarEvent(id: "google:evt123", title: title, start: eventStart, end: eventEnd, attendees: attendees)
}

// MARK: - Helpers

private func makeFixture() async throws -> StageFixture {
    let fixture = try await StageFixture()
    try fixture.plantTranscript()
    return fixture
}

private func rawJSON(at url: URL) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
}

private func readCalendar(_ fixture: StageFixture) throws -> CalendarArtifact {
    try JSONDecoder().decode(CalendarArtifact.self, from: Data(contentsOf: fixture.calendarURL()))
}

private func fileText(_ url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
}

/// Runs the persist stage over the `summary.json` the summarize stage left and
/// returns the note it published.
private func publishedNote(_ fixture: StageFixture) async throws -> String {
    let vault = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: vault.appendingPathComponent("Meetings"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: vault) }

    let persisted = try await PersistStage.run(
        meetingID: fixture.meetingID,
        cacheDirectory: CacheArtifactWriter.cacheDirectory(for: fixture.meetingID),
        vaultPath: vault,
        meetingsSubdir: "Meetings",
        stateStore: fixture.store,
        stageRunner: fixture.runner,
    )
    guard case .completed = persisted else {
        Issue.record("expected the persist stage to complete, got \(persisted)")
        return ""
    }
    let notePath = try #require(try await fixture.store.fetchMeeting(id: fixture.meetingID.rawValue)?.vaultNotePath)
    return try String(contentsOfFile: notePath, encoding: .utf8)
}

/// The shape every run that found no usable event must have, whatever the
/// reason: the stage completes, `calendar.json` says so and carries no
/// event, the summary is the generic unenriched one, the meeting row is
/// untouched, and the summarizer was given no attendees. Then persist
/// publishes a note the frontmatter reader still parses.
private func expectDegradedRun(
    _ fixture: StageFixture,
    outcome: StageRunner.StageOutcome,
    primary: StageStubStrategy,
    source: StubCalendarSource? = nil,
) async throws {
    guard case let .completed(targetState, _) = outcome else {
        Issue.record("expected .completed outcome, got \(outcome)")
        return
    }
    #expect(targetState == .persisting)
    if let source {
        #expect(await source.authorizeCount == 0)
    }

    let calendar = try readCalendar(fixture)
    #expect(calendar == CalendarArtifact(degraded: true, event: nil))
    let raw = try rawJSON(at: fixture.calendarURL())
    #expect(raw["degraded"] as? Bool == true)
    #expect(raw["event"] == nil)
    #expect(raw["schema_version"] as? Int == 1)

    let summary = try fixture.readSummary()
    #expect(summary.title == stageExpectedTitle)
    #expect(summary.calendarEventTitle == nil)
    #expect(summary.attendees.isEmpty)
    #expect(summary.selfWikilink == nil)
    #expect(summary.needsCalendarEnrichment)

    #expect(await primary.lastConfig?.attendeeNames == [])

    let row = try #require(try await fixture.store.fetchMeeting(id: fixture.meetingID.rawValue))
    #expect(row.title == nil)
    #expect(row.calendarEventID == nil)

    let note = try await publishedNote(fixture)
    #expect(note.contains("title: \"\(stageExpectedTitle)\""))
    #expect(note.contains("- auricle/meeting"))
    #expect(note.contains("- auricle/needs-calendar-enrichment"))
    #expect(note.contains("attendees: []"))
    let parsed = try FrontmatterReader.read(noteContents: note)
    #expect(parsed.meetingID == fixture.meetingID)
    #expect(parsed.attendees.isEmpty)
}

private func runExpectingDegradation(_ source: StubCalendarSource?) async throws {
    let fixture = try await makeFixture()
    defer { fixture.cleanUp() }
    let primary = StageStubStrategy(.success(makeStageGrounded()))

    let outcome = try await fixture.run(primary: primary, calendarSource: source)

    try await expectDegradedRun(fixture, outcome: outcome, primary: primary, source: source)
}

// MARK: - Match found

@Test func aMatchedEventFillsTheCalendarArtifactTheSummaryThePromptAndTheMeetingRow() async throws {
    let fixture = try await makeFixture()
    defer { fixture.cleanUp() }
    let primary = StageStubStrategy(.success(makeStageGrounded()))
    let source = StubCalendarSource(.success(makeEvent()))

    let outcome = try await fixture.run(primary: primary, calendarSource: source)

    guard case .completed = outcome else {
        Issue.record("expected .completed outcome, got \(outcome)")
        return
    }
    #expect(await source.fetchCount == 1)
    #expect(await source.authorizeCount == 0)
    #expect(await source.requestedDates == [ISO8601UTC.date(from: stageDefaultCaptureStartedAt)])

    #expect(try readCalendar(fixture) == CalendarArtifact(
        degraded: false,
        event: CalendarEventArtifact(
            eventID: "google:evt123",
            title: "Weekly Sync",
            start: "2026-04-28T12:00:00Z",
            end: "2026-04-28T13:00:00Z",
            attendees: [
                CalendarAttendeeArtifact(displayName: "Ada Lovelace", isSelf: true),
                CalendarAttendeeArtifact(displayName: "Ben Ng", isSelf: false),
            ],
        ),
    ))
    #expect(try rawJSON(at: fixture.calendarURL())["schema_version"] as? Int == 1)

    let summary = try fixture.readSummary()
    #expect(summary.title == "Weekly Sync")
    #expect(summary.calendarEventTitle == "Weekly Sync")
    #expect(summary.attendees == ["[[Ada Lovelace]]", "[[Ben Ng]]"])
    #expect(summary.selfWikilink == "[[Ada Lovelace]]")
    #expect(!summary.needsCalendarEnrichment)

    #expect(await primary.lastConfig?.attendeeNames == ["Ada Lovelace", "Ben Ng"])

    let row = try #require(try await fixture.store.fetchMeeting(id: fixture.meetingID.rawValue))
    #expect(row.title == "Weekly Sync")
    #expect(row.calendarEventID == "google:evt123")
    #expect(row.state == "persisting")
    #expect(try await fixture.state() == "persisting")
}

@Test func aMatchedEventPublishesTheStandardNoteThatTheReaderParses() async throws {
    let fixture = try await makeFixture()
    defer { fixture.cleanUp() }
    let primary = StageStubStrategy(.success(makeStageGrounded()))

    _ = try await fixture.run(primary: primary, calendarSource: StubCalendarSource(.success(makeEvent())))
    let note = try await publishedNote(fixture)

    #expect(note.contains("title: \"Weekly Sync\""))
    #expect(note.contains("- auricle/meeting"))
    #expect(!note.contains("auricle/needs-calendar-enrichment"))
    let parsed = try FrontmatterReader.read(noteContents: note)
    #expect(parsed.meetingID == fixture.meetingID)
    #expect(parsed.attendees == ["[[Ada Lovelace]]", "[[Ben Ng]]"])
}

@Test func theStageOwnsTheAttendeeNamesSoACallerSuppliedListNeverReachesTheStrategy() async throws {
    let fixture = try await makeFixture()
    defer { fixture.cleanUp() }
    let primary = StageStubStrategy(.success(makeStageGrounded()))
    let config = SummarizerConfig(modelIdentifier: "claude-test-model", effortLevel: .high, attendeeNames: ["Stale Name"])

    _ = try await fixture.run(primary: primary, config: config, calendarSource: nil)

    let seen = try #require(await primary.lastConfig)
    #expect(seen.attendeeNames == [])
    #expect(seen.modelIdentifier == "claude-test-model")
    #expect(seen.effortLevel == .high)
}

@Test func theRowRefreshKeepsColumnsChangedWhileTheSummarizerRan() async throws {
    let fixture = try await makeFixture()
    defer { fixture.cleanUp() }
    let store = fixture.store
    let meetingID = fixture.meetingID
    let primary = StageStubStrategy(.success(makeStageGrounded())) {
        guard var row = try await store.fetchMeeting(id: meetingID.rawValue) else { return }
        row.audioCachePath = "/cache/audio.m4a"
        try await store.updateMeeting(row)
    }

    _ = try await fixture.run(primary: primary, calendarSource: StubCalendarSource(.success(makeEvent())))

    let row = try #require(try await store.fetchMeeting(id: meetingID.rawValue))
    #expect(row.audioCachePath == "/cache/audio.m4a")
    #expect(row.title == "Weekly Sync")
    #expect(row.calendarEventID == "google:evt123")
}

// MARK: - Degraded variants

@Test func noMatchDegradesToTheGenericTitleAndBothTags() async throws {
    try await runExpectingDegradation(StubCalendarSource(.success(nil)))
}

@Test func anUnreachableCalendarDegradesAndTheStageStillCompletes() async throws {
    try await runExpectingDegradation(StubCalendarSource(.failure(CalendarError.unreachable)))
}

@Test func anExpiredAuthorizationDegradesAndTheStageStillCompletes() async throws {
    try await runExpectingDegradation(StubCalendarSource(.failure(CalendarError.authorizationExpired)))
}

@Test func aForeignErrorDegradesAndItsMessageNeverReachesAnyArtifact() async throws {
    let secret = "response-body-\(UUID().uuidString)"
    let fixture = try await makeFixture()
    defer { fixture.cleanUp() }
    let primary = StageStubStrategy(.success(makeStageGrounded()))

    let source = StubCalendarSource(.failure(StageLeakyError(secret: secret)))

    let outcome = try await fixture.run(primary: primary, calendarSource: source)

    try await expectDegradedRun(fixture, outcome: outcome, primary: primary, source: source)
    #expect(try !fileText(fixture.calendarURL()).contains(secret))
    #expect(try !fileText(fixture.summaryURL()).contains(secret))
    for event in try await fixture.events() {
        #expect(event.errorMessage?.contains(secret) != true)
        #expect(event.metadataJSON?.contains(secret) != true)
    }
}

@Test func anErrorIsNamedByCaseOrTypeAndNeverByItsMessage() {
    let secret = "response-body-\(UUID().uuidString)"

    #expect(CalendarEnrichment.errorName(CalendarError.unreachable) == "CalendarError.unreachable")
    #expect(CalendarEnrichment.errorName(CalendarError.authorizationExpired) == "CalendarError.authorizationExpired")
    let foreign = CalendarEnrichment.errorName(StageLeakyError(secret: secret))
    #expect(foreign.contains("StageLeakyError"))
    #expect(!foreign.contains(secret))
}

@Test func aBlankTitleCountsAsNoEventAtAll() async throws {
    let fixture = try await makeFixture()
    defer { fixture.cleanUp() }
    let primary = StageStubStrategy(.success(makeStageGrounded()))

    let source = StubCalendarSource(.success(makeEvent(title: "  \n ")))

    let outcome = try await fixture.run(primary: primary, calendarSource: source)

    try await expectDegradedRun(fixture, outcome: outcome, primary: primary, source: source)
}

@Test func noSourceDegradesWithoutAnyLookup() async throws {
    try await runExpectingDegradation(nil)
}

@Test func aCalendarJSONThatCannotBeWrittenIsIgnoredAndTheSummaryStillLands() async throws {
    let fixture = try await makeFixture()
    defer { fixture.cleanUp() }
    // A directory where the file belongs makes the atomic rename fail.
    try FileManager.default.createDirectory(at: fixture.calendarURL(), withIntermediateDirectories: true)
    let primary = StageStubStrategy(.success(makeStageGrounded()))

    let outcome = try await fixture.run(primary: primary, calendarSource: StubCalendarSource(.success(makeEvent())))

    guard case .completed = outcome else {
        Issue.record("expected .completed outcome, got \(outcome)")
        return
    }
    #expect(try fixture.readSummary().title == "Weekly Sync")
    var isDirectory: ObjCBool = false
    #expect(try FileManager.default.fileExists(atPath: fixture.calendarURL().path, isDirectory: &isDirectory) && isDirectory.boolValue)
}

// MARK: - Cancellation and ordering

@Test func cancellationFromTheSourceEndsTheStageAsAFailureWithoutCallingTheSummarizer() async throws {
    let fixture = try await makeFixture()
    defer { fixture.cleanUp() }
    let primary = StageStubStrategy(.success(makeStageGrounded()))

    let outcome = try await fixture.run(primary: primary, calendarSource: StubCalendarSource(.failure(CancellationError())))

    try await expectStageFailure(outcome, fixture: fixture, errorClass: "summarize_unexpected_error")
    #expect(await primary.callCount == 0)
    #expect(try !FileManager.default.fileExists(atPath: fixture.calendarURL().path))
}

/// A run that fails on an input the stage checks before the lookup: it must
/// end with the expected class having asked the source for nothing, and left
/// no `calendar.json` behind.
private func expectNoLookup(
    _ fixture: StageFixture,
    errorClass: String,
    promptSetHash: (@Sendable (SummarizationMode) throws -> String)? = nil,
) async throws {
    let source = StubCalendarSource(.success(makeEvent()))
    let primary = StageStubStrategy(.success(makeStageGrounded()))

    let outcome = try await fixture.run(primary: primary, calendarSource: source, promptSetHash: promptSetHash)

    try await expectStageFailure(outcome, fixture: fixture, errorClass: errorClass)
    #expect(await source.fetchCount == 0)
    #expect(await primary.callCount == 0)
    #expect(try !FileManager.default.fileExists(atPath: fixture.calendarURL().path))
}

@Test func aMissingTranscriptNeverCostsACalendarLookup() async throws {
    let fixture = try await StageFixture()
    defer { fixture.cleanUp() }

    try await expectNoLookup(fixture, errorClass: "transcript_missing")
}

@Test func aMalformedAttributionNeverCostsACalendarLookup() async throws {
    let fixture = try await makeFixture()
    defer { fixture.cleanUp() }
    try CacheArtifactWriter.write(["speakers": ["not", "a", "map"]], for: fixture.meetingID, named: "attribution.json", schemaVersion: 1)

    try await expectNoLookup(fixture, errorClass: "attribution_undecodable")
}

@Test func aMissingCaptureStartNeverCostsACalendarLookup() async throws {
    let fixture = try await StageFixture(captureStartedAt: nil)
    defer { fixture.cleanUp() }
    try fixture.plantTranscript()

    try await expectNoLookup(fixture, errorClass: "capture_started_at_missing")
}

@Test func anUtteranceOutsideTheTranscriptNeverCostsACalendarLookup() async throws {
    let fixture = try await StageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantTranscript(CanonicalTranscript(text: "short", utterances: [.init(speakerLabel: "Speaker_1", start: 0, end: 99)]))

    try await expectNoLookup(fixture, errorClass: "segment_extraction_failed")
}

@Test func anUnresolvablePromptSetNeverCostsACalendarLookup() async throws {
    let fixture = try await makeFixture()
    defer { fixture.cleanUp() }

    try await expectNoLookup(fixture, errorClass: "prompt_set_unavailable") { _ in
        throw StageLeakyError(secret: "/private/prompt/path")
    }
}

/// Cancels its own task, then fails the way a cancelled transport does: with
/// an error that is not a `CancellationError`.
private struct SelfCancellingCalendarSource: CalendarSource {
    func authorize() async throws {}

    func fetchActiveEvent(at _: Date) async throws -> CalendarEvent? {
        withUnsafeCurrentTask { $0?.cancel() }
        throw URLError(.cancelled)
    }

    func upcomingEvents(in _: TimeInterval) async throws -> [CalendarEvent] {
        []
    }
}

@Test func anErrorFromACancelledTaskStillEndsTheLookupWithCancellation() async {
    let lookup = Task {
        try await CalendarEnrichment.resolve(using: SelfCancellingCalendarSource(), at: Date())
    }

    await #expect(throws: CancellationError.self) {
        try await lookup.value
    }
}

@Test func aSummarizerFailureLeavesTheMeetingRowUnrefreshed() async throws {
    let fixture = try await makeFixture()
    defer { fixture.cleanUp() }
    let primary = StageStubStrategy(.failure(SummarizerError.quotaExceeded))
    let source = StubCalendarSource(.success(makeEvent()))

    let outcome = try await fixture.run(primary: primary, calendarSource: source)

    try await expectStageFailure(outcome, fixture: fixture, errorClass: "summarizer_quota_exceeded")
    let row = try #require(try await fixture.store.fetchMeeting(id: fixture.meetingID.rawValue))
    #expect(row.title == nil)
    #expect(row.calendarEventID == nil)
}

// MARK: - Attendee names

@Test func anAttendeeWithOnlyAnEmailIsOmittedAndTheAddressAppearsNowhere() async throws {
    let secretEmail = "only.an.email@example.com"
    let event = makeEvent(attendees: [
        CalendarAttendee(email: privateEmail, displayName: "Ada Lovelace", isSelf: true),
        CalendarAttendee(email: secretEmail, displayName: nil, isSelf: false),
        CalendarAttendee(email: "blank@example.com", displayName: " [[ ]] | ", isSelf: false),
    ])
    let fixture = try await makeFixture()
    defer { fixture.cleanUp() }
    let primary = StageStubStrategy(.success(makeStageGrounded()))

    _ = try await fixture.run(primary: primary, calendarSource: StubCalendarSource(.success(event)))
    let note = try await publishedNote(fixture)

    #expect(await primary.lastConfig?.attendeeNames == ["Ada Lovelace"])
    let summary = try fixture.readSummary()
    #expect(summary.attendees == ["[[Ada Lovelace]]"])
    #expect(try readCalendar(fixture).event?.attendees == [
        CalendarAttendeeArtifact(displayName: "Ada Lovelace", isSelf: true),
        CalendarAttendeeArtifact(displayName: nil, isSelf: false),
        CalendarAttendeeArtifact(displayName: nil, isSelf: false),
    ])

    let everything = try [fileText(fixture.calendarURL()), fileText(fixture.summaryURL()), note].joined(separator: "\n")
    for email in [privateEmail, secretEmail, "blank@example.com"] {
        #expect(!everything.contains(email))
    }
}

@Test func anAttendeeNamedByAnEmailAddressIsOmittedFromEveryOutput() async throws {
    let addressAsName = "ada.typed@example.com"
    let event = makeEvent(attendees: [
        CalendarAttendee(email: "ben@example.com", displayName: "Ben Ng", isSelf: true),
        CalendarAttendee(email: "ada@example.com", displayName: addressAsName, isSelf: false),
    ])
    let fixture = try await makeFixture()
    defer { fixture.cleanUp() }
    let primary = StageStubStrategy(.success(makeStageGrounded()))

    _ = try await fixture.run(primary: primary, calendarSource: StubCalendarSource(.success(event)))
    let note = try await publishedNote(fixture)

    #expect(await primary.lastConfig?.attendeeNames == ["Ben Ng"])
    #expect(try readCalendar(fixture).event?.attendees == [
        CalendarAttendeeArtifact(displayName: "Ben Ng", isSelf: true),
        CalendarAttendeeArtifact(displayName: nil, isSelf: false),
    ])
    #expect(try fixture.readSummary().attendees == ["[[Ben Ng]]"])
    let everything = try [fileText(fixture.calendarURL()), fileText(fixture.summaryURL()), note].joined(separator: "\n")
    #expect(!everything.contains(addressAsName))
}

@Test func aHostileDisplayNameIsSanitizedBeforeItIsWikilinked() async throws {
    let event = makeEvent(attendees: [
        CalendarAttendee(email: "ben@example.com", displayName: "Ben]] | #x", isSelf: true),
    ])
    let fixture = try await makeFixture()
    defer { fixture.cleanUp() }
    let primary = StageStubStrategy(.success(makeStageGrounded()))

    _ = try await fixture.run(primary: primary, calendarSource: StubCalendarSource(.success(event)))

    let summary = try fixture.readSummary()
    #expect(summary.attendees == ["[[Ben x]]"])
    #expect(summary.selfWikilink == "[[Ben x]]")
    #expect(await primary.lastConfig?.attendeeNames == ["Ben x"])
    #expect(try readCalendar(fixture).event?.attendees == [CalendarAttendeeArtifact(displayName: "Ben x", isSelf: true)])
}

@Test func sanitizingRemovesLinkSyntaxAndControlCharactersAndCollapsesWhitespace() {
    #expect(CalendarEnrichment.sanitizedName("Ben]] | #x") == "Ben x")
    #expect(CalendarEnrichment.sanitizedName("[[Ada^Lovelace\\]]") == "AdaLovelace")
    #expect(CalendarEnrichment.sanitizedName("  Ada \t\n  Lovelace  ") == "Ada Lovelace")
    #expect(CalendarEnrichment.sanitizedName("Ben\u{0}\u{7}\u{1B}Ng") == "BenNg")
    #expect(CalendarEnrichment.sanitizedName("Zoë Ñandú 🚀") == "Zoë Ñandú 🚀")
    #expect(CalendarEnrichment.sanitizedName("[[]] | # ^ \\ \u{0}") == nil)
    #expect(CalendarEnrichment.sanitizedName("   ") == nil)
    #expect(CalendarEnrichment.sanitizedName("ada@example.com") == nil)
    #expect(CalendarEnrichment.sanitizedName("Ada <ada@example.com>") == nil)
    #expect(CalendarEnrichment.sanitizedName("") == nil)
}

@Test func onlyTheOwnerWithAUsableNameSetsTheSelfWikilink() async throws {
    let event = makeEvent(attendees: [
        CalendarAttendee(email: "owner@example.com", displayName: nil, isSelf: true),
        CalendarAttendee(email: "ben@example.com", displayName: "Ben Ng", isSelf: false),
    ])
    let fixture = try await makeFixture()
    defer { fixture.cleanUp() }
    let primary = StageStubStrategy(.success(makeStageGrounded()))

    _ = try await fixture.run(primary: primary, calendarSource: StubCalendarSource(.success(event)))

    let summary = try fixture.readSummary()
    #expect(summary.selfWikilink == nil)
    #expect(summary.attendees == ["[[Ben Ng]]"])
}
