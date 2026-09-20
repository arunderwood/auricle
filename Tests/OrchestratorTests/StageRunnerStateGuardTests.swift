@testable import Core
import Foundation
import GRDB
@testable import Orchestrator
@testable import State
@testable import Telemetry
import Testing

/// A 26-character, Crockford-base32-safe (no `I`/`L`/`O`/`U`) stand-in ULID:
/// `MeetingID(ulid:)` validates its shape, and the sweep skips any row that
/// fails that validation, so fixtures must actually pass it.
private func meetingID(_ tag: String) -> String {
    let prefix = "01" + tag
    return prefix + String(repeating: "9", count: 26 - prefix.count)
}

private func makeMeeting(id: String, state: String, updatedAt: String = "2026-01-01T00:00:00Z") -> Meeting {
    Meeting(id: id, state: state, createdAt: "2026-01-01T00:00:00Z", updatedAt: updatedAt)
}

private func isoString(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

private func makeStore() throws -> StateStore {
    try StateStore.forTesting(writer: DatabaseQueue())
}

private func makeRunner(
    store: StateStore,
    now: @escaping @Sendable () -> Date = { Date() },
    log: Log = Log(category: "orchestrator"),
) -> StageRunner {
    StageRunner(stateStore: store, stageEventLogger: StageEventLogger(stateStore: store), now: now, log: log)
}

// MARK: - `synthesizeFailure`: the state guard

@Test func synthesizeFailureWritesNothingWhenARealWriteBumpedUpdatedAtSinceTheRead() async throws {
    let store = try makeStore()
    let id = meetingID("GRD1")
    try await store.insertMeeting(makeMeeting(id: id, state: "transcribing", updatedAt: "2026-01-01T00:00:00Z"))
    let runner = makeRunner(store: store)
    let resolvedID = try #require(MeetingID(ulid: id))

    // Transcribe completes into its own active state, which leaves `state`
    // unchanged: only `updated_at` tells this write from the one that was read.
    _ = try await runner.run(stage: .transcribe, meetingID: resolvedID, activeState: .transcribing) {
        .completed(targetState: .transcribing)
    }
    let eventsBefore = try await store.fetchStageEvents(meetingID: id)

    await #expect(throws: StateStoreError.staleWrite(id: id)) {
        try await runner.synthesizeFailure(
            meetingID: resolvedID,
            stage: .transcribe,
            activeState: .transcribing,
            reason: .staleActiveState(budgetSeconds: 60),
            expectedUpdatedAt: "2026-01-01T00:00:00Z",
        )
    }

    #expect(try await store.fetchStageEvents(meetingID: id) == eventsBefore)
    #expect(!eventsBefore.contains { $0.event == "failed" })
    #expect(try await store.fetchMeeting(id: id)?.state == "transcribing")
}

@Test func synthesizeFailureAlwaysGuardsOnTheActiveStateItWasGiven() async throws {
    let store = try makeStore()
    let id = meetingID("GRD2")
    try await store.insertMeeting(makeMeeting(id: id, state: "published"))
    let runner = makeRunner(store: store)
    let resolvedID = try #require(MeetingID(ulid: id))

    await #expect(throws: StateStoreError.staleWrite(id: id)) {
        try await runner.synthesizeFailure(
            meetingID: resolvedID,
            stage: .summarize,
            activeState: .summarizing,
            reason: .staleActiveState(budgetSeconds: 720),
        )
    }

    #expect(try await store.fetchStageEvents(meetingID: id).isEmpty)
    #expect(try await store.fetchMeeting(id: id)?.state == "published")
}

@Test func synthesizeFailureRecordsTheFailureWhenTheRowIsUnchangedSinceTheRead() async throws {
    let store = try makeStore()
    let id = meetingID("GRD3")
    try await store.insertMeeting(makeMeeting(id: id, state: "summarizing", updatedAt: "2026-01-01T00:00:00Z"))
    let recorder = LogRecorder()
    let runner = makeRunner(store: store, log: recorder.log)
    let resolvedID = try #require(MeetingID(ulid: id))

    try await runner.synthesizeFailure(
        meetingID: resolvedID,
        stage: .summarize,
        activeState: .summarizing,
        reason: .staleActiveState(budgetSeconds: 720),
        expectedUpdatedAt: "2026-01-01T00:00:00Z",
    )

    #expect(try await store.fetchMeeting(id: id)?.state == "summarization_failed")
    #expect(try await store.fetchStageEvents(meetingID: id).map(\.event) == ["failed"])
    #expect(recorder.records.map(\.level) == [.error])
}

/// The sweep reads a snapshot, and a real completed write lands before the
/// sweep writes its failure. Handing the sweep the earlier snapshot is exactly
/// that interleaving.
@Test func theSweepLosesToARealTransitionThatLandedAfterItRead() async throws {
    let store = try makeStore()
    let id = meetingID("GRD4")
    let fixedNow = Date(timeIntervalSince1970: 1_735_000_000)
    try await store.insertMeeting(makeMeeting(id: id, state: "transcribing", updatedAt: isoString(fixedNow.addingTimeInterval(-100))))
    let recorder = LogRecorder()
    let runner = makeRunner(store: store, log: recorder.log)
    let resolvedID = try #require(MeetingID(ulid: id))

    let snapshot = try await store.fetchPending()
    _ = try await runner.run(stage: .transcribe, meetingID: resolvedID, activeState: .transcribing) {
        .completed(targetState: .transcribing)
    }
    let infoRecordsBeforeSweep = recorder.records.count

    let transitioned = await runner.sweep(candidates: snapshot, asOf: fixedNow)

    #expect(transitioned.isEmpty)
    let events = try await store.fetchStageEvents(meetingID: id)
    #expect(events.map(\.event) == ["started", "completed"])
    #expect(try await store.fetchMeeting(id: id)?.state == "transcribing")

    let sweepRecords = Array(recorder.records.dropFirst(infoRecordsBeforeSweep))
    #expect(sweepRecords.map(\.level) == [.info])
    #expect(sweepRecords[0].message.contains("moved since it was read"))
}

@Test func theSweepStillFailsAMeetingThatIsUnchangedSinceItRead() async throws {
    let store = try makeStore()
    let id = meetingID("GRD5")
    let fixedNow = Date(timeIntervalSince1970: 1_735_000_000)
    try await store.insertMeeting(makeMeeting(id: id, state: "summarizing", updatedAt: isoString(fixedNow.addingTimeInterval(-800))))
    let runner = makeRunner(store: store)

    let transitioned = try await runner.sweepStaleActiveStates(now: fixedNow)

    #expect(transitioned.map(\.rawValue) == [id])
    #expect(try await store.fetchMeeting(id: id)?.state == "summarization_failed")
}

// MARK: - Stale budgets, pinned by value

/// Literals on purpose: reading the expectation back from the table would pass
/// for any value the table holds.
@Test func theStaleBudgetTableHasExactlyTheDecision42Values() {
    #expect(StageRunner.staleDetectionBudgetSeconds == [
        .transcribing: 60,
        .reviewingDiarization: 90,
        .summarizing: 720,
        .persisting: 60,
        .published: 30,
    ])
}

private struct BudgetCase: Sendable, CustomTestStringConvertible {
    let state: PipelineState
    let budgetSeconds: Double
    let stateAfterSweep: String

    var testDescription: String {
        state.rawValue
    }
}

@Test(arguments: [
    BudgetCase(state: .transcribing, budgetSeconds: 60, stateAfterSweep: "transcription_failed"),
    BudgetCase(state: .reviewingDiarization, budgetSeconds: 90, stateAfterSweep: "awaiting_attribution"),
    BudgetCase(state: .summarizing, budgetSeconds: 720, stateAfterSweep: "summarization_failed"),
    BudgetCase(state: .persisting, budgetSeconds: 60, stateAfterSweep: "persist_failed"),
    BudgetCase(state: .published, budgetSeconds: 30, stateAfterSweep: "awaiting_verification"),
])
private func aMeetingOneSecondUnderItsBudgetIsLeftAloneAndOneAtItIsSwept(_ budgetCase: BudgetCase) async throws {
    let store = try makeStore()
    let runner = makeRunner(store: store)
    let fixedNow = Date(timeIntervalSince1970: 1_735_000_000)
    let underBudget = meetingID("BDG1")
    let atBudget = meetingID("BDG2")
    let state = budgetCase.state.rawValue

    try await store.insertMeeting(makeMeeting(id: underBudget, state: state, updatedAt: isoString(fixedNow.addingTimeInterval(-(budgetCase.budgetSeconds - 1)))))
    try await store.insertMeeting(makeMeeting(id: atBudget, state: state, updatedAt: isoString(fixedNow.addingTimeInterval(-budgetCase.budgetSeconds))))

    let transitioned = try await runner.sweepStaleActiveStates(now: fixedNow)

    #expect(transitioned.map(\.rawValue) == [atBudget])
    #expect(try await store.fetchMeeting(id: underBudget)?.state == state)
    #expect(try await store.fetchMeeting(id: atBudget)?.state == budgetCase.stateAfterSweep)
}

// MARK: - `run`: the guarded start

@Test func runWritesNothingWhenTheMeetingIsNotInTheStateTheCallerRead() async throws {
    let store = try makeStore()
    let id = meetingID("GRD2")
    try await store.insertMeeting(makeMeeting(id: id, state: "awaiting_attribution"))
    let runner = makeRunner(store: store)
    let resolvedID = try #require(MeetingID(ulid: id))
    let ran = LockedFlag()

    await #expect(throws: StateStoreError.staleWrite(id: id)) {
        _ = try await runner.run(stage: .notify, meetingID: resolvedID, activeState: .published, expectedState: .published) {
            ran.set()
            return .completed(targetState: .awaitingVerification)
        }
    }

    #expect(!ran.isSet)
    #expect(try await store.fetchMeeting(id: id)?.state == "awaiting_attribution")
    #expect(try await store.fetchStageEvents(meetingID: id).isEmpty)
}

@Test func runProceedsWhenTheMeetingIsInTheStateTheCallerRead() async throws {
    let store = try makeStore()
    let id = meetingID("GRD3")
    try await store.insertMeeting(makeMeeting(id: id, state: "published"))
    let runner = makeRunner(store: store)
    let resolvedID = try #require(MeetingID(ulid: id))

    _ = try await runner.run(stage: .notify, meetingID: resolvedID, activeState: .published, expectedState: .published) {
        .completed(targetState: .awaitingVerification)
    }

    #expect(try await store.fetchMeeting(id: id)?.state == "awaiting_verification")
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isSet: Bool {
        lock.withLock { flag }
    }

    func set() {
        lock.withLock { flag = true }
    }
}
