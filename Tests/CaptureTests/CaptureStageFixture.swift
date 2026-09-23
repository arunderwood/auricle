@testable import Capture
import Core
import Foundation
import GRDB
import Notifications
@testable import State
import Telemetry
import Testing

final class Box<Value>: @unchecked Sendable {
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
final class Gate: @unchecked Sendable {
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

struct FakeFailure: Error, CustomStringConvertible {
    let description: String
}

/// A `CaptureRecording` with no audio hardware. `stop()` returns whatever WAV
/// the test put at `audioURL`; `emit` stands in for an input reporting a fault.
final class FakeRecording: CaptureRecording, @unchecked Sendable {
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

final class RecordingNotifier: Notifier {
    let captureFailures = Box<[(MeetingID, CaptureFailureReason)]>([])

    func fire(meetingID _: MeetingID, title _: String, vaultPath _: String) async {}

    func fireCaptureFailed(meetingID: MeetingID, reason: CaptureFailureReason) async {
        captureFailures.value.append((meetingID, reason))
    }
}

struct StageFixture {
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

    /// `sleep` paces the system-audio backoff. The default parks it until
    /// the capture ends, so a test that does not exercise the backoff never
    /// sees an attempt and never waits in real time.
    func stage(
        session: FakeRecording?,
        timeZone: TimeZone? = nil,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in try await Task.sleep(for: .seconds(3600)) },
    ) -> CaptureStage {
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
            // Distinct per attempt, so a test can read which delay an
            // attempt recorded; `sleep` decides whether any time passes.
            systemAudioRetryDelay: { .milliseconds(5 * ($0 + 1)) },
            sleep: sleep,
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

func metadata(_ event: StageEvent?) throws -> CaptureMeta {
    let json = try #require(event?.metadataJSON)
    return try JSONDecoder().decode(CaptureMeta.self, from: Data(json.utf8))
}

/// The timeout only bounds a failing test: a passing condition returns on the
/// first poll that sees it. It is generous because a loaded CI runner can
/// starve the cooperative pool for several seconds before a background task
/// such as the system-audio backoff is scheduled.
func eventually(timeout: TimeInterval = 30, _ condition: () async throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while try await !condition() {
        if Date() > deadline {
            Issue.record("condition not met within \(timeout)s")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
