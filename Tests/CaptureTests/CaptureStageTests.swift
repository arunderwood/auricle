@testable import Capture
import Core
import Foundation
import GRDB
import Notifications
@testable import State
import Telemetry
import Testing

private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Holds whoever calls `wait()` until `release()`, and records that someone
/// reached it.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    let reached = Box(false)

    func wait() async {
        reached.value = true
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if isOpen {
                    return true
                }
                waiters.append(continuation)
                return false
            }
            if resumeNow {
                continuation.resume()
            }
        }
    }

    func release() {
        let pending = lock.withLock {
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        pending.forEach { $0.resume() }
    }
}

private struct FakeFailure: Error, CustomStringConvertible {
    let description: String
}

/// A `CaptureRecording` with no audio hardware. `stop()` returns whatever WAV
/// the test put at `audioURL`; `emit` stands in for an input reporting a fault.
private final class FakeRecording: CaptureRecording, @unchecked Sendable {
    let faults: AsyncStream<CaptureStreamFault>
    private let continuation: AsyncStream<CaptureStreamFault>.Continuation
    let audioURL: URL

    let micIncluded: Bool
    let startError: Error?
    let stopError: Error?
    let restartErrors = Box<[Error]>([])
    let stats = Box(CaptureWatchdogStats())
    let stopCount = Box(0)
    let restarts = Box<[CaptureSource]>([])
    /// When set, `start()` or `stop()` suspends on it before doing anything
    /// else. A gated `stop()` leaves `faults` open until released.
    let startGate: Gate?
    let stopGate: Gate?

    init(
        audioURL: URL,
        micIncluded: Bool = true,
        startError: Error? = nil,
        stopError: Error? = nil,
        startGate: Gate? = nil,
        stopGate: Gate? = nil,
    ) {
        self.startGate = startGate
        self.stopGate = stopGate
        (faults, continuation) = AsyncStream<CaptureStreamFault>.makeStream()
        self.audioURL = audioURL
        self.micIncluded = micIncluded
        self.startError = startError
        self.stopError = stopError
    }

    var watchdogStats: CaptureWatchdogStats {
        stats.value
    }

    func start() async throws -> CaptureSessionStartResult {
        await startGate?.wait()
        if let startError {
            throw startError
        }
        return CaptureSessionStartResult(micIncluded: micIncluded)
    }

    func stop() async throws -> URL {
        stopCount.value += 1
        await stopGate?.wait()
        continuation.finish()
        if let stopError {
            throw stopError
        }
        return audioURL
    }

    func restart(_ source: CaptureSource) async throws {
        restarts.value.append(source)
        var errors = restartErrors.value
        if !errors.isEmpty {
            let error = errors.removeFirst()
            restartErrors.value = errors
            throw error
        }
    }

    func emit(_ fault: CaptureStreamFault) {
        continuation.yield(fault)
    }
}

private final class RecordingNotifier: Notifier {
    let captureFailures = Box<[(MeetingID, CaptureFailureReason)]>([])

    func fire(meetingID _: MeetingID, title _: String, vaultPath _: String) async {}

    func fireCaptureFailed(meetingID: MeetingID, reason: CaptureFailureReason) async {
        captureFailures.value.append((meetingID, reason))
    }
}

private struct StageFixture {
    let store: StateStore
    let logger: StageEventLogger
    let root: URL
    let notifier = RecordingNotifier()
    let clock = Box(Date(timeIntervalSince1970: 1_800_000_000))
    let captured = Box<[MeetingID]>([])
    let id = MeetingID.generate()

    init() throws {
        store = try StateStore.forTesting(writer: DatabaseQueue())
        logger = StageEventLogger(stateStore: store)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("auricle-capture-stage-tests-\(UUID().uuidString)", isDirectory: true)
    }

    func audioURL(_ id: MeetingID) -> URL {
        root.appendingPathComponent(id.rawValue).appendingPathComponent("audio.wav")
    }

    func recording(
        micIncluded: Bool = true,
        startError: Error? = nil,
        stopError: Error? = nil,
        startGate: Gate? = nil,
        stopGate: Gate? = nil,
    ) -> FakeRecording {
        FakeRecording(
            audioURL: audioURL(id),
            micIncluded: micIncluded,
            startError: startError,
            stopError: stopError,
            startGate: startGate,
            stopGate: stopGate,
        )
    }

    func stage(session: FakeRecording?, timeZone: TimeZone? = nil) -> CaptureStage {
        let root = root
        let clock = clock
        let captured = captured
        let zone: @Sendable () -> TimeZone = if let timeZone {
            { timeZone }
        } else {
            { TimeZone.current }
        }
        return CaptureStage(
            stateStore: store,
            stageEventLogger: logger,
            notifier: notifier,
            makeSession: { _ in session ?? FakeRecording(audioURL: URL(fileURLWithPath: "/nonexistent")) },
            cacheDirectory: { root.appendingPathComponent($0.rawValue, isDirectory: true) },
            now: { clock.value },
            timeZone: zone,
            onCaptured: { captured.value.append($0) },
        )
    }

    /// A finalized WAV holding `seconds` of silence, where the session would
    /// have written it.
    func writeFinalizedWAV(seconds: Int, for id: MeetingID) throws {
        let writer = try WAVWriter(meetingID: id, cacheDirectory: { root.appendingPathComponent($0.rawValue, isDirectory: true) })
        try writer.write(Data(count: seconds * AudioImporter.sampleRate * 2))
        try writer.finalize()
    }

    func meeting(_ id: MeetingID) async throws -> Meeting {
        try #require(try await store.fetchMeeting(id: id.rawValue))
    }

    func events(_ id: MeetingID) async throws -> [StageEvent] {
        try await store.fetchStageEvents(meetingID: id.rawValue)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func metadata(_ event: StageEvent?) throws -> CaptureMeta {
    let json = try #require(event?.metadataJSON)
    return try JSONDecoder().decode(CaptureMeta.self, from: Data(json.utf8))
}

private func waitUntil(timeout: TimeInterval = 3, _ condition: () async throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while try await !condition() {
        if Date() > deadline {
            Issue.record("condition not met within \(timeout)s")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

// MARK: - Start

@Test func startWritesARecordingRowWithItsZoneAndOneStartedEvent() async throws {
    let fixture = try StageFixture()
    defer { fixture.cleanUp() }
    let stage = fixture.stage(session: fixture.recording())

    let result = try await stage.start(meetingID: fixture.id)

    #expect(result == CaptureStartResult(meetingID: fixture.id, micIncluded: true))
    let meeting = try await fixture.meeting(fixture.id)
    #expect(meeting.state == "recording")
    #expect(meeting.captureStartedAt == ISO8601UTC.string(from: fixture.clock.value))
    #expect(meeting.audioCachePath == fixture.audioURL(fixture.id).path)
    #expect(meeting.captureTimeZone == TimeZone.current.identifier)
    let events = try await fixture.events(fixture.id)
    #expect(events.map(\.stage) == ["capture"])
    #expect(events.map(\.event) == ["started"])
}

@Test func aDeniedMicrophoneStillStartsAndIsReported() async throws {
    let fixture = try StageFixture()
    defer { fixture.cleanUp() }
    let zone = try #require(TimeZone(identifier: "Pacific/Auckland"))
    let stage = fixture.stage(session: fixture.recording(micIncluded: false), timeZone: zone)

    let result = try await stage.start(meetingID: fixture.id)

    #expect(!result.micIncluded)
    let meeting = try await fixture.meeting(fixture.id)
    #expect(meeting.state == "recording")
    #expect(meeting.captureTimeZone == "Pacific/Auckland")
}

@Test func aSessionThatFailsToStartLeavesACaptureFailedRowAndRethrows() async throws {
    let fixture = try StageFixture()
    defer { fixture.cleanUp() }
    let stage = fixture.stage(session: fixture.recording(startError: FakeFailure(description: "no tap")))

    await #expect(throws: FakeFailure.self) {
        _ = try await stage.start(meetingID: fixture.id)
    }

    #expect(try await fixture.meeting(fixture.id).state == "capture_failed")
    let events = try await fixture.events(fixture.id)
    #expect(events.map(\.event) == ["started", "failed"])
    #expect(try metadata(events.last).errorClass == "start_failed")
}

// MARK: - Stop

@Test func stopMovesTheCaptureToCapturedWithItsMetadataAndHandsItOn() async throws {
    let fixture = try StageFixture()
    defer { fixture.cleanUp() }
    let session = fixture.recording()
    session.stats.value = CaptureWatchdogStats(exactZeroSeconds: 12.5, rebuildCount: 2)
    let stage = fixture.stage(session: session)
    _ = try await stage.start(meetingID: fixture.id)
    try fixture.writeFinalizedWAV(seconds: 3, for: fixture.id)
    fixture.clock.value = fixture.clock.value.addingTimeInterval(4)

    let state = try await stage.stop(meetingID: fixture.id)

    #expect(state == .captured)
    let meeting = try await fixture.meeting(fixture.id)
    #expect(meeting.state == "captured")
    #expect(meeting.captureEndedAt == ISO8601UTC.string(from: fixture.clock.value))
    #expect(meeting.durationSeconds == 3)
    let events = try await fixture.events(fixture.id)
    #expect(events.map(\.event) == ["started", "completed"])
    #expect(try metadata(events.last) == CaptureMeta(micIncluded: true, exactZeroSeconds: 12.5, tapRebuilds: 2))
    try await waitUntil { fixture.captured.value == [fixture.id] }
}

@Test func aSecondStopReturnsTheRowsStateAndWritesNothing() async throws {
    let fixture = try StageFixture()
    defer { fixture.cleanUp() }
    let stage = fixture.stage(session: fixture.recording())
    _ = try await stage.start(meetingID: fixture.id)
    try fixture.writeFinalizedWAV(seconds: 1, for: fixture.id)
    _ = try await stage.stop(meetingID: fixture.id)

    #expect(try await stage.stop(meetingID: fixture.id) == .captured)
    #expect(try await fixture.events(fixture.id).map(\.event) == ["started", "completed"])
}

@Test func stoppingAMeetingThatDoesNotExistIsMeetingNotFound() async throws {
    let fixture = try StageFixture()
    defer { fixture.cleanUp() }
    let stage = fixture.stage(session: nil)

    await #expect(throws: StateStoreError.meetingNotFound(id: fixture.id.rawValue)) {
        _ = try await stage.stop(meetingID: fixture.id)
    }
}

@Test func aSessionThatCannotFinalizeFailsTheCaptureAsInterrupted() async throws {
    let fixture = try StageFixture()
    defer { fixture.cleanUp() }
    let stage = fixture.stage(session: fixture.recording(stopError: FakeFailure(description: "disk gone")))
    _ = try await stage.start(meetingID: fixture.id)

    #expect(try await stage.stop(meetingID: fixture.id) == .captureFailed)

    let events = try await fixture.events(fixture.id)
    #expect(events.map(\.event) == ["started", "failed"])
    #expect(try metadata(events.last).errorClass == "interrupted")
    #expect(fixture.captured.value.isEmpty)
}

// MARK: - Recovery

@Test func recoveryRepairsAnInterruptedWAVAndMovesTheRowToCaptured() async throws {
    let fixture = try StageFixture()
    defer { fixture.cleanUp() }
    _ = try await fixture.stage(session: fixture.recording()).start(meetingID: fixture.id)
    // What a crash leaves: samples on disk, the placeholder header never
    // patched.
    do {
        let writer = try WAVWriter(meetingID: fixture.id, cacheDirectory: { fixture.root.appendingPathComponent($0.rawValue, isDirectory: true) })
        try writer.write(Data(count: 2 * AudioImporter.sampleRate * 2))
    }

    let outcomes = try await fixture.stage(session: nil).recoverInterruptedCaptures()

    #expect(outcomes == [CaptureRecoveryOutcome(meetingID: fixture.id, state: .captured)])
    let meeting = try await fixture.meeting(fixture.id)
    #expect(meeting.state == "captured")
    #expect(meeting.durationSeconds == 2)
    let startedAt = try #require(meeting.captureStartedAt.flatMap(ISO8601UTC.date(from:)))
    #expect(meeting.captureEndedAt == ISO8601UTC.string(from: startedAt.addingTimeInterval(2)))
    #expect(meeting.audioCachePath == fixture.audioURL(fixture.id).path)
    let events = try await fixture.events(fixture.id)
    #expect(events.map(\.event) == ["started", "completed"])
    #expect(try metadata(events.last).reason == "recovered_after_interruption")

    let header = try Data(contentsOf: fixture.audioURL(fixture.id)).subdata(in: 40 ..< 44)
    #expect(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } == UInt32(2 * AudioImporter.sampleRate * 2).littleEndian)
    #expect(fixture.captured.value.isEmpty)
}

@Test(arguments: ["missing", "header-only", "not-a-wav"])
func recoveryWithoutUsableAudioFailsTheCaptureAsInterrupted(audio: String) async throws {
    let fixture = try StageFixture()
    defer { fixture.cleanUp() }
    _ = try await fixture.stage(session: fixture.recording()).start(meetingID: fixture.id)
    let url = fixture.audioURL(fixture.id)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    switch audio {
    case "header-only":
        _ = try WAVWriter(meetingID: fixture.id, cacheDirectory: { fixture.root.appendingPathComponent($0.rawValue, isDirectory: true) })
    case "not-a-wav":
        try AtomicWriter.write(Data(repeating: 0x41, count: 4096), to: url)
    default:
        break
    }

    let outcomes = try await fixture.stage(session: nil).recoverInterruptedCaptures()

    #expect(outcomes == [CaptureRecoveryOutcome(meetingID: fixture.id, state: .captureFailed)])
    let events = try await fixture.events(fixture.id)
    #expect(events.map(\.event) == ["started", "failed"])
    #expect(try metadata(events.last).errorClass == "interrupted")
}

@Test func recoveryLeavesALiveCaptureAlone() async throws {
    let fixture = try StageFixture()
    defer { fixture.cleanUp() }
    let stage = fixture.stage(session: fixture.recording())
    _ = try await stage.start(meetingID: fixture.id)

    #expect(try await stage.recoverInterruptedCaptures().isEmpty)
    #expect(try await fixture.meeting(fixture.id).state == "recording")
}

// MARK: - Faults

@Test func aReportedRevocationSavesTheAudioFailsTheCaptureAndNotifies() async throws {
    let fixture = try StageFixture()
    defer { fixture.cleanUp() }
    let session = fixture.recording()
    let stage = fixture.stage(session: session)
    _ = try await stage.start(meetingID: fixture.id)

    session.emit(.permissionRevoked(.microphone))
    try await waitUntil { try await fixture.meeting(fixture.id).state == "capture_failed" }

    #expect(session.stopCount.value == 1)
    #expect(try await fixture.meeting(fixture.id).audioCachePath == fixture.audioURL(fixture.id).path)
    let events = try await fixture.events(fixture.id)
    #expect(events.map(\.event) == ["started", "failed"])
    let meta = try metadata(events.last)
    #expect(meta.errorClass == "permission_revoked_midstream")
    #expect(meta.source == "microphone")
    try await waitUntil { !fixture.notifier.captureFailures.value.isEmpty }
    #expect(fixture.notifier.captureFailures.value.map(\.0) == [fixture.id])
    #expect(fixture.notifier.captureFailures.value.map(\.1) == [.permissionRevokedMidstream])
    #expect(try await stage.stop(meetingID: fixture.id) == .captureFailed)
}

@Test func twoTransientFaultsRestartInlineAndTheThirdFailsTheCapture() async throws {
    let fixture = try StageFixture()
    defer { fixture.cleanUp() }
    let session = fixture.recording()
    let stage = fixture.stage(session: session)
    _ = try await stage.start(meetingID: fixture.id)

    session.emit(.transient(.systemAudio, reason: "device lost"))
    session.emit(.transient(.microphone, reason: "engine stopped"))
    try await waitUntil { session.restarts.value.count == 2 }
    #expect(session.restarts.value == [.systemAudio, .microphone])
    try await waitUntil { try await fixture.events(fixture.id).count == 3 }
    let retried = try await fixture.events(fixture.id).filter { $0.event == "retried" }
    #expect(try retried.map { try metadata($0).source } == ["system_audio", "microphone"])
    #expect(try await fixture.meeting(fixture.id).state == "recording")

    session.emit(.transient(.systemAudio, reason: "device lost again"))
    try await waitUntil { try await fixture.meeting(fixture.id).state == "capture_failed" }

    #expect(session.restarts.value.count == 2)
    #expect(session.stopCount.value == 1)
    let events = try await fixture.events(fixture.id)
    #expect(events.map(\.event) == ["started", "retried", "retried", "failed"])
    #expect(try metadata(events.last).errorClass == "transient_stream_errors")
    #expect(fixture.notifier.captureFailures.value.isEmpty)
}

@Test func aRestartThatThrowsCountsAsTheNextFault() async throws {
    let fixture = try StageFixture()
    defer { fixture.cleanUp() }
    let session = fixture.recording()
    session.restartErrors.value = [FakeFailure(description: "rebuild failed")]
    let stage = fixture.stage(session: session)
    _ = try await stage.start(meetingID: fixture.id)

    session.emit(.transient(.systemAudio, reason: "device lost"))
    try await waitUntil { session.restarts.value.count == 2 }
    try await waitUntil { try await fixture.events(fixture.id).count == 3 }
    #expect(try await fixture.meeting(fixture.id).state == "recording")

    session.emit(.transient(.systemAudio, reason: "device lost again"))
    try await waitUntil { try await fixture.meeting(fixture.id).state == "capture_failed" }
    #expect(try await metadata(fixture.events(fixture.id).last).errorClass == "transient_stream_errors")
}

@Test func aMicrophoneRestartThatFindsTheGrantRevokedFailsAsARevocation() async throws {
    let fixture = try StageFixture()
    defer { fixture.cleanUp() }
    let session = fixture.recording()
    session.restartErrors.value = [CaptureError.permissionRevokedMidstream]
    let stage = fixture.stage(session: session)
    _ = try await stage.start(meetingID: fixture.id)

    session.emit(.transient(.microphone, reason: "engine stopped"))
    try await waitUntil { try await fixture.meeting(fixture.id).state == "capture_failed" }

    #expect(try await metadata(fixture.events(fixture.id).last).errorClass == "permission_revoked_midstream")
    try await waitUntil { fixture.notifier.captureFailures.value.count == 1 }
}

/// A fault that arrives while `stop` is still finalizing meets a capture
/// that has left `.running`, and is ignored.
@Test func aFaultDuringStopIsIgnored() async throws {
    let fixture = try StageFixture()
    defer { fixture.cleanUp() }
    let gate = Gate()
    let session = fixture.recording(stopGate: gate)
    let stage = fixture.stage(session: session)
    _ = try await stage.start(meetingID: fixture.id)
    try fixture.writeFinalizedWAV(seconds: 1, for: fixture.id)

    let stopping = Task { try await stage.stop(meetingID: fixture.id) }
    try await waitUntil { gate.reached.value }
    session.emit(.transient(.systemAudio, reason: "device lost"))
    session.emit(.permissionRevoked(.microphone))
    try await Task.sleep(for: .milliseconds(50))
    gate.release()

    #expect(try await stopping.value == .captured)
    #expect(try await fixture.events(fixture.id).map(\.event) == ["started", "completed"])
    #expect(session.restarts.value.isEmpty)
    #expect(session.stopCount.value == 1)
    #expect(fixture.notifier.captureFailures.value.isEmpty)
}

/// A stop that arrives while the session is still starting returns
/// `recording`, and is carried out once the start completes.
@Test func aStopDuringStartIsCarriedOutOnceTheSessionHasStarted() async throws {
    let fixture = try StageFixture()
    defer { fixture.cleanUp() }
    let gate = Gate()
    let stage = fixture.stage(session: fixture.recording(startGate: gate))
    try fixture.writeFinalizedWAV(seconds: 1, for: fixture.id)

    let starting = Task { try await stage.start(meetingID: fixture.id) }
    try await waitUntil { gate.reached.value }
    #expect(try await stage.stop(meetingID: fixture.id) == .recording)
    gate.release()

    #expect(try await starting.value == CaptureStartResult(meetingID: fixture.id, micIncluded: true))
    #expect(try await fixture.meeting(fixture.id).state == "captured")
    #expect(try await fixture.events(fixture.id).map(\.event) == ["started", "completed"])
    try await waitUntil { fixture.captured.value == [fixture.id] }
}
