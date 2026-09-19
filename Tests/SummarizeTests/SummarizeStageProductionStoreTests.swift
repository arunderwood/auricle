import Core
import Foundation
import GRDB
import State
import SummarizerInterface
import Testing

/// `StateStore.production(path:)` enforces foreign keys, as the real GUI and
/// subprocess openers do; the in-memory store every other stage test uses does
/// not. Without the stage's own existence check, the missing row would surface
/// as a `DatabaseError` from `StageRunner`'s first transaction instead of the
/// typed error the worker maps to its own exit code.
@Test func missingMeetingUnderTheProductionConfiguredStoreThrowsMeetingNotFoundAndLeavesNoTrace() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try StateStore.production(path: directory.appendingPathComponent("auricle.sqlite3").path)

    let fixture = try await StageFixture(insertMeetingRow: false, store: store)
    defer { fixture.cleanUp() }
    try fixture.plantTranscript()
    let primary = StageStubStrategy(.success(makeStageGrounded()))

    await #expect(throws: StateStoreError.meetingNotFound(id: fixture.meetingID.rawValue)) {
        try await fixture.run(primary: primary)
    }

    let summaryURL = try fixture.summaryURL()
    #expect(!FileManager.default.fileExists(atPath: summaryURL.path))
    #expect(try await fixture.events().isEmpty)
    #expect(try await fixture.store.fetchTelemetry(meetingID: fixture.meetingID.rawValue) == nil)
    #expect(try await fixture.store.fetchMeeting(id: fixture.meetingID.rawValue) == nil)
    #expect(await primary.callCount == 0)

    // Proves this store really rejects rows for a meeting that does not exist:
    // were foreign keys off, the assertions above would hold for the wrong reason.
    // Last, because a store that accepted the row would otherwise leave an event behind.
    let orphan = StageEvent(
        meetingID: fixture.meetingID.rawValue,
        stage: "summarize",
        event: "started",
        occurredAt: "2026-04-28T12:00:00Z",
    )
    await #expect(throws: DatabaseError.self) {
        try await fixture.store.insertStageEvent(orphan)
    }
}
