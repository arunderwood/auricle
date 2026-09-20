@testable import Core
import Foundation
import GRDB
@testable import Orchestrator
@testable import State
import Testing

/// Counts how often `SubprocessDispatcher` looks up the worker executable,
/// which it does on every dispatch attempt, successful or not.
private final class LookupCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        value += 1
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private func makeStore() throws -> StateStore {
    try StateStore.forTesting(writer: DatabaseQueue())
}

/// A 26-character, Crockford-base32-safe (no `I`/`L`/`O`/`U`) stand-in ULID.
private func meetingIDString(_ tag: String) -> String {
    let prefix = "01" + tag
    return prefix + String(repeating: "9", count: 26 - prefix.count)
}

private func makeMeeting(id: String, state: String) -> Meeting {
    Meeting(id: id, state: state, createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z")
}

/// A stub `auricle-cli` stand-in: `CrashRecovery` needs a real, launchable
/// executable behind `SubprocessDispatcher` to prove re-dispatch actually
/// spawns something, since the real binary doesn't exist until Story 1.7.
private func makeStubDispatcher() throws -> (dispatcher: SubprocessDispatcher, cleanup: () -> Void) {
    let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("stub-auricle-cli-\(UUID().uuidString)")
    try "#!/bin/sh\nexit 0\n".write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    let dispatcher = SubprocessDispatcher(resolveExecutablePath: { scriptURL }, resolveVaultPath: { nil })
    return (dispatcher, { try? FileManager.default.removeItem(at: scriptURL) })
}

/// Simulates a subprocess that crashed between Txn A and Txn B (AR-PIPE-3):
/// the meeting sits in its active state with only an orphan `started`
/// `stage_events` row and no matching `completed`/`failed` row.
@Test func reconcileRedispatchesEachOfTheThreeAutomaticallySubprocessResumableActiveStates() async throws {
    let store = try makeStore()
    let (dispatcher, cleanup) = try makeStubDispatcher()
    defer { cleanup() }

    let transcribing = meetingIDString("CR01")
    let reviewing = meetingIDString("CR02")
    let summarizing = meetingIDString("CR03")
    let notInCrashRecoveryQuery = meetingIDString("CR05")

    try await store.insertMeeting(makeMeeting(id: transcribing, state: "transcribing"))
    try await store.insertStageEvent(StageEvent(meetingID: transcribing, stage: "transcribe", event: "started", occurredAt: "2026-01-01T00:00:00Z"))

    try await store.insertMeeting(makeMeeting(id: reviewing, state: "reviewing_diarization"))
    try await store.insertStageEvent(StageEvent(meetingID: reviewing, stage: "review-diarization", event: "started", occurredAt: "2026-01-01T00:00:00Z"))

    try await store.insertMeeting(makeMeeting(id: summarizing, state: "summarizing"))
    // Outside the AC's literal `WHERE state IN (...)` query — must be left alone.
    try await store.insertMeeting(makeMeeting(id: notInCrashRecoveryQuery, state: "awaiting_attribution"))

    let recovery = CrashRecovery(stateStore: store, dispatcher: dispatcher)
    let outcomes = try await recovery.reconcile()

    let redispatched = Dictionary(uniqueKeysWithValues: outcomes.compactMap { outcome -> (String, PipelineStage)? in
        guard case let .redispatched(id, stage) = outcome else { return nil }
        return (id.rawValue, stage)
    })

    #expect(redispatched[transcribing] == .transcribe)
    #expect(redispatched[reviewing] == .reviewDiarization)
    #expect(redispatched[summarizing] == .summarize)
    #expect(redispatched[notInCrashRecoveryQuery] == nil)
    #expect(outcomes.count == 3)

    // The orphan `started` row is retained as forensic audit trail, not
    // cleaned up or replaced by crash recovery itself.
    let transcribingEvents = try await store.fetchStageEvents(meetingID: transcribing)
    #expect(transcribingEvents.map(\.event) == ["started"])
}

/// `published` is waiting on `notify`, which runs in-process per AR-PIPE-1 —
/// unlike the 3 subprocess-backed active states, crash recovery must never
/// spawn `auricle-cli __internal-stage notify <id>` for it.
@Test func reconcileLogsPublishedWithoutRedispatchingSinceNotifyRunsInProcess() async throws {
    let store = try makeStore()
    let (dispatcher, cleanup) = try makeStubDispatcher()
    defer { cleanup() }

    let published = meetingIDString("CR04")
    try await store.insertMeeting(makeMeeting(id: published, state: "published"))

    let recovery = CrashRecovery(stateStore: store, dispatcher: dispatcher)
    let outcomes = try await recovery.reconcile()

    #expect(outcomes.count == 1)
    guard case let .loggedOnly(id, state) = outcomes[0] else {
        Issue.record("expected a .loggedOnly outcome, got \(outcomes)")
        return
    }
    #expect(id.rawValue == published)
    #expect(state == .published)
}

@Test func reconcileLogsAttributingWithoutRedispatchingSinceItIsUserPaced() async throws {
    let store = try makeStore()
    let (dispatcher, cleanup) = try makeStubDispatcher()
    defer { cleanup() }

    let attributing = meetingIDString("CR06")
    try await store.insertMeeting(makeMeeting(id: attributing, state: "attributing"))

    let recovery = CrashRecovery(stateStore: store, dispatcher: dispatcher)
    let outcomes = try await recovery.reconcile()

    #expect(outcomes.count == 1)
    guard case let .loggedOnly(id, state) = outcomes[0] else {
        Issue.record("expected a .loggedOnly outcome, got \(outcomes)")
        return
    }
    #expect(id.rawValue == attributing)
    #expect(state == .attributing)

    // Crash recovery only reasons about a stuck `attributing` meeting; it
    // performs no transition and writes no `stage_events` row for it.
    let events = try await store.fetchStageEvents(meetingID: attributing)
    #expect(events.isEmpty)
    let meeting = try #require(try await store.fetchMeeting(id: attributing))
    #expect(meeting.state == "attributing")
}

/// `persisting` is waiting on `persist`, which runs in-process per AR-PIPE-1.
/// Dispatching it as a subprocess would either fail or, if mapped to
/// `summarize`, repeat a paid summarization for a summary already on disk.
@Test func reconcileLogsPersistingWithoutDispatchingAnyStage() async throws {
    let store = try makeStore()
    let lookups = LookupCounter()
    let dispatcher = SubprocessDispatcher(
        resolveExecutablePath: {
            lookups.increment()
            return nil
        },
        resolveVaultPath: { nil },
    )

    let persisting = meetingIDString("CR07")
    try await store.insertMeeting(makeMeeting(id: persisting, state: "persisting"))
    try await store.insertStageEvent(StageEvent(meetingID: persisting, stage: "persist", event: "started", occurredAt: "2026-01-01T00:00:00Z"))

    let recovery = CrashRecovery(stateStore: store, dispatcher: dispatcher)
    let outcomes = try await recovery.reconcile()

    #expect(outcomes.count == 1)
    guard case let .loggedOnly(id, state) = outcomes[0] else {
        Issue.record("expected a .loggedOnly outcome, got \(outcomes)")
        return
    }
    #expect(id.rawValue == persisting)
    #expect(state == .persisting)
    #expect(lookups.count == 0)

    let events = try await store.fetchStageEvents(meetingID: persisting)
    #expect(events.map(\.event) == ["started"])
    let meeting = try #require(try await store.fetchMeeting(id: persisting))
    #expect(meeting.state == "persisting")
}

@Test func reconcileStillDispatchesSummarizeForASummarizingMeeting() async throws {
    let store = try makeStore()
    let (dispatcher, cleanup) = try makeStubDispatcher()
    defer { cleanup() }

    let summarizing = meetingIDString("CR08")
    try await store.insertMeeting(makeMeeting(id: summarizing, state: "summarizing"))

    let recovery = CrashRecovery(stateStore: store, dispatcher: dispatcher)
    let outcomes = try await recovery.reconcile()

    let summarizingID = try #require(MeetingID(ulid: summarizing))
    #expect(outcomes == [.redispatched(summarizingID, .summarize)])
}

// MARK: - The worker's exit status

/// The worker blocks until the test lets it go, so `reconcile()` having already
/// returned while it runs proves reconcile does not wait on the process.
@Test(arguments: [2 as Int32, 64])
func reconcileObservesTheWorkersNonzeroExitAfterReturningAtOnce(exitCode: Int32) async throws {
    let store = try makeStore()
    let gate = FileManager.default.temporaryDirectory.appendingPathComponent("gate-\(UUID().uuidString)")
    let stub = try makeStubExecutable(exitCode: exitCode, waitingFor: gate)
    defer {
        try? FileManager.default.removeItem(at: stub)
        try? FileManager.default.removeItem(at: gate)
    }
    let dispatcher = SubprocessDispatcher(resolveExecutablePath: { stub }, resolveVaultPath: { nil })
    let id = meetingIDString("CR07")
    try await store.insertMeeting(makeMeeting(id: id, state: "transcribing"))
    let collector = WorkerExitCollector()
    let recovery = CrashRecovery(stateStore: store, dispatcher: dispatcher, onWorkerExit: collector.add)

    let outcomes = try await recovery.reconcile()

    let meetingID = try #require(MeetingID(ulid: id))
    #expect(outcomes == [.redispatched(meetingID, .transcribe)])
    #expect(collector.exits.isEmpty)

    FileManager.default.createFile(atPath: gate.path, contents: nil)

    #expect(await waitUntil { collector.exits.count == 1 })
    #expect(collector.exits == [WorkerExit(stage: .transcribe, meetingID: meetingID, status: exitCode)])
}

@Test func theDefaultObserverWarnsForANonzeroStatusOnly() throws {
    let recorder = LogRecorder()
    let id = try #require(MeetingID(ulid: meetingIDString("CR08")))

    CrashRecovery.warnOnNonzeroExit(WorkerExit(stage: .summarize, meetingID: id, status: 0), to: recorder.log)
    #expect(recorder.records.isEmpty)

    CrashRecovery.warnOnNonzeroExit(WorkerExit(stage: .summarize, meetingID: id, status: 64), to: recorder.log)
    #expect(recorder.records.map(\.level) == [.default])
    #expect(recorder.records[0].message.contains("status=64"))
    #expect(recorder.records[0].message.contains("stage=summarize"))
    #expect(recorder.records[0].message.contains("meetingID=\(id)"))
}

/// The default observer is what every real caller gets: nothing constructs a
/// `CrashRecovery` with an observer yet. A worker that fails at argument
/// parsing exits 64, and without this it would look like one that finished.
@Test func reconcileWithNoObserverWarnsWhenTheReDispatchedWorkerExitsNonzero() async throws {
    let store = try makeStore()
    let stub = try makeStubExecutable(exitCode: 64)
    defer { try? FileManager.default.removeItem(at: stub) }
    let dispatcher = SubprocessDispatcher(resolveExecutablePath: { stub }, resolveVaultPath: { nil })
    let id = meetingIDString("CR10")
    try await store.insertMeeting(makeMeeting(id: id, state: "summarizing"))
    let recorder = LogRecorder()

    _ = try await CrashRecovery(stateStore: store, dispatcher: dispatcher, onWorkerExit: nil, log: recorder.log).reconcile()

    #expect(await waitUntil { recorder.records.contains { $0.level == .default } })
    let warning = try #require(recorder.records.first { $0.level == .default })
    #expect(warning.message.contains("status=64"))
    #expect(warning.message.contains("stage=summarize"))
    #expect(warning.message.contains("meetingID=\(id)"))
}

@Test func reconcileWithNoObserverStillRedispatchesAndReturns() async throws {
    let store = try makeStore()
    let (dispatcher, cleanup) = try makeStubDispatcher()
    defer { cleanup() }
    let id = meetingIDString("CR09")
    try await store.insertMeeting(makeMeeting(id: id, state: "summarizing"))

    let outcomes = try await CrashRecovery(stateStore: store, dispatcher: dispatcher).reconcile()

    #expect(outcomes.count == 1)
}
