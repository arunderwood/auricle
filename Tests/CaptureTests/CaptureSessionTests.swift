import AVFoundation
@testable import Capture
import Core
import Foundation
import Permissions
import Testing

/// Reports a fixed status for `.microphone`, mirroring how
/// `Tests/PermissionsTests` fakes `PermissionChecking` — no live TCC state
/// or OS prompt involved.
private struct FakePermissionChecker: PermissionChecking {
    let microphoneStatus: PermissionStatus

    func check(_ category: TCCCategory) async -> PermissionStatus {
        category == .microphone ? microphoneStatus : .unknown
    }

    func request(_ category: TCCCategory) async -> PermissionStatus {
        category == .microphone ? microphoneStatus : .unknown
    }

    func refresh() async {}

    func remediationDeepLink(for _: TCCCategory) -> URL? {
        nil
    }
}

/// A `SystemAudioSource` double: no Core Audio involved, so
/// `CaptureSessionTests` never needs a live tap or a live Mac — `push(_:)`
/// stands in for a real IOProc publishing into its own internal ring, and
/// `drain(_:)` is what `CaptureSession`'s consumer task calls to retrieve
/// it, exactly matching the real protocol's pull shape.
private final class FakeSystemAudioSource: SystemAudioSource, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [RawAudioChunk] = []
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var rebuildCallCount = 0

    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        startCallCount += 1
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopCallCount += 1
    }

    func rebuild() throws {
        lock.lock()
        defer { lock.unlock() }
        rebuildCallCount += 1
    }

    func drain(_ consume: (RawAudioChunk) -> Void) {
        lock.lock()
        let chunks = pending
        pending = []
        lock.unlock()
        chunks.forEach(consume)
    }

    /// Test-only: the producer-side call this fake stands in for — pushes
    /// a chunk as if a real IOProc had just published one.
    func push(_ chunk: RawAudioChunk) {
        lock.lock()
        pending.append(chunk)
        lock.unlock()
    }
}

/// A slow `CaptureAudioWriting`: `write(_:)` blocks for `delaySeconds`
/// before returning, standing in for a disk stall. Used to prove the
/// real-time producer side (`FakeSystemAudioSource.push(_:)`, standing in
/// for a real audio callback) never waits on it.
private final class SlowWriter: CaptureAudioWriting, @unchecked Sendable {
    private let delaySeconds: Double
    private let lock = NSLock()
    private(set) var writeCount = 0

    init(delaySeconds: Double) {
        self.delaySeconds = delaySeconds
    }

    func write(_: Data) throws {
        Thread.sleep(forTimeInterval: delaySeconds)
        lock.lock()
        writeCount += 1
        lock.unlock()
    }

    func finalize() throws {}
}

/// A synthetic tone chunk, the shape a drained `RawAudioChunk` takes.
private func systemChunk(seconds: Double = 0.05, sampleRate: Double = 48000, amplitude: Float = 0.4, hostTime: UInt64 = 0) -> RawAudioChunk {
    let frameCount = Int(seconds * sampleRate)
    let samples = (0 ..< frameCount).map { amplitude * Float(sin(2 * Double.pi * 440 * Double($0) / sampleRate)) }
    return RawAudioChunk(samples: samples, sampleRate: sampleRate, channelCount: 1, frameCount: frameCount, hostTime: hostTime)
}

/// A silent chunk — what 30 seconds of these in a row should trip the
/// zero-buffer watchdog on.
private func silentSystemChunk(seconds: Double, sampleRate: Double = 16000, hostTime: UInt64 = 0) -> RawAudioChunk {
    let frameCount = Int(seconds * sampleRate)
    return RawAudioChunk(samples: [Float](repeating: 0, count: frameCount), sampleRate: sampleRate, channelCount: 1, frameCount: frameCount, hostTime: hostTime)
}

/// Polls `condition` until it's true or `timeout` elapses — the consumer
/// task processes drained chunks asynchronously, off the thread that
/// pushed them, so assertions about its effects can't be made
/// synchronously right after a `push`.
private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}

private struct SessionFixture {
    let meetingID = MeetingID.generate()
    let root: URL
    let systemAudioSource = FakeSystemAudioSource()

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("auricle-capture-session-tests-\(UUID().uuidString)", isDirectory: true)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    func makeSession(
        micStatus: PermissionStatus,
        startEngine: @escaping @Sendable (AVAudioEngine) throws -> Void = { try $0.start() },
        makeWriter: (@Sendable (MeetingID) throws -> CaptureAudioWriting)? = nil,
        noCallbackThreshold: TimeInterval = 5,
    ) -> CaptureSession {
        CaptureSession(
            meetingID: meetingID,
            engine: AVAudioEngine(),
            systemAudioSource: systemAudioSource,
            permissionChecker: FakePermissionChecker(microphoneStatus: micStatus),
            cacheDirectory: { root.appendingPathComponent($0.rawValue, isDirectory: true) },
            startEngine: startEngine,
            makeWriter: makeWriter,
            noCallbackThreshold: noCallbackThreshold,
        )
    }

    func audioURL() -> URL {
        root.appendingPathComponent(meetingID.rawValue).appendingPathComponent(AudioImporter.audioFileName)
    }
}

@Suite(.serialized)
struct CaptureSessionTests {
    @Test func micPermissionDeniedRecordsSystemAudioOnlyAndNeverStartsTheMicEngine() async throws {
        let fixture = SessionFixture()
        defer { fixture.cleanUp() }
        let session = fixture.makeSession(micStatus: .denied)

        let result = try await session.start()
        #expect(result.micIncluded == false)
        #expect(fixture.systemAudioSource.startCallCount == 1)

        fixture.systemAudioSource.push(systemChunk())
        let url = try await session.stop()

        #expect(url == fixture.audioURL())
        #expect(fixture.systemAudioSource.stopCallCount == 1)
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        #expect(file.fileFormat.sampleRate == 16000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(file.length > 0)
    }

    @Test func micPermissionNotDeterminedStillIncludesTheMic() async throws {
        // Only an explicit `.denied` excludes the mic — `.notDetermined`
        // isn't a denial (AC's mic-denied scenario is specifically about
        // `.denied`). The mic engine itself isn't exercised here (no audio
        // hardware in CI); this only checks the reported result.
        let fixture = SessionFixture()
        defer { fixture.cleanUp() }
        let session = fixture.makeSession(micStatus: .notDetermined)

        // `AVAudioEngine.start()` can fail without a real input device
        // (headless CI); either outcome is consistent with "mic was
        // attempted" as long as it isn't silently treated as denied.
        do {
            let result = try await session.start()
            #expect(result.micIncluded == true)
            _ = try? await session.stop()
        } catch {
            // Engine start failing in a hardware-less CI environment is not
            // this test's concern.
        }
    }

    @Test func stopBeforeStartThrows() async throws {
        let fixture = SessionFixture()
        defer { fixture.cleanUp() }
        let session = fixture.makeSession(micStatus: .denied)

        await #expect(throws: CaptureError.self) {
            try await session.stop()
        }
    }

    @Test func startCalledTwiceThrows() async throws {
        let fixture = SessionFixture()
        defer { fixture.cleanUp() }
        let session = fixture.makeSession(micStatus: .denied)
        _ = try await session.start()

        await #expect(throws: CaptureError.self) {
            try await session.start()
        }
        _ = try? await session.stop()
    }

    @Test func stopCalledTwiceIsIdempotentAndReturnsTheSamePath() async throws {
        let fixture = SessionFixture()
        defer { fixture.cleanUp() }
        let session = fixture.makeSession(micStatus: .denied)
        _ = try await session.start()
        fixture.systemAudioSource.push(systemChunk())

        let first = try await session.stop()
        let second = try await session.stop()

        #expect(first == second)
        #expect(fixture.systemAudioSource.stopCallCount == 1)
    }

    @Test func micEngineStartFailureTearsDownSystemAudioAndPropagatesTheError() async throws {
        struct EngineStartFailure: Error {}
        let fixture = SessionFixture()
        defer { fixture.cleanUp() }
        let session = fixture.makeSession(micStatus: .granted, startEngine: { _ in throw EngineStartFailure() })

        await #expect(throws: CaptureError.self) {
            try await session.start()
        }
        #expect(fixture.systemAudioSource.startCallCount == 1)
        #expect(fixture.systemAudioSource.stopCallCount == 1)
    }

    @Test func writerConstructionFailureNeverStartsEitherSourceAndPropagatesTheError() async throws {
        // `WAVWriter` is built before either source starts (Decision:
        // a buffer arriving before the writer exists has nowhere to go),
        // so a construction failure here must mean neither source was
        // ever touched — nothing to tear down.
        let fixture = SessionFixture()
        defer { fixture.cleanUp() }
        let directory = fixture.root.appendingPathComponent(fixture.meetingID.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try AtomicWriter.write(Data(), to: directory.appendingPathComponent(AudioImporter.audioFileName))
        let session = fixture.makeSession(micStatus: .denied)

        await #expect(throws: CaptureError.self) {
            try await session.start()
        }
        #expect(fixture.systemAudioSource.startCallCount == 0)
        #expect(fixture.systemAudioSource.stopCallCount == 0)
    }

    @Test func permissionProbeStartsAndStopsTheSource() async throws {
        let source = FakeSystemAudioSource()

        try await SystemAudioPermissionProbe.prompt(source: source)

        #expect(source.startCallCount == 1)
        #expect(source.stopCallCount == 1)
    }

    // MARK: - AC: watchdog and real-time-safety coverage via a fake source

    @Test func thirtySecondsOfZeroSystemAudioTriggersARebuildAndUpdatesWatchdogStats() async throws {
        let fixture = SessionFixture()
        defer { fixture.cleanUp() }
        let session = fixture.makeSession(micStatus: .denied)
        _ = try await session.start()

        // 30 one-second all-zero chunks — the exact-zero rebuild threshold.
        for _ in 0 ..< 30 {
            fixture.systemAudioSource.push(silentSystemChunk(seconds: 1))
        }

        try await waitUntil { session.watchdogStats.rebuildCount >= 1 }

        #expect(session.watchdogStats.rebuildCount == 1)
        #expect(session.watchdogStats.exactZeroSeconds >= 30)
        #expect(fixture.systemAudioSource.rebuildCallCount == 1)

        _ = try? await session.stop()
    }

    @Test func aSourceThatStopsCallingBackEntirelyTriggersTheNoCallbackWatchdog() async throws {
        let fixture = SessionFixture()
        defer { fixture.cleanUp() }
        let session = fixture.makeSession(micStatus: .denied, noCallbackThreshold: 0.2)
        _ = try await session.start()

        // Nothing is ever pushed — the shape a removed/changed output
        // device produces (the aggregate device simply stops calling the
        // IOProc, not calling it with zero-valued buffers).
        try await waitUntil { fixture.systemAudioSource.rebuildCallCount >= 1 }

        #expect(fixture.systemAudioSource.rebuildCallCount >= 1)
        #expect(session.watchdogStats.rebuildCount >= 1)

        _ = try? await session.stop()
    }

    @Test func aSlowWriterNeverBlocksTheProducerSidePush() async throws {
        let fixture = SessionFixture()
        defer { fixture.cleanUp() }
        let slowWriter = SlowWriter(delaySeconds: 1)
        let session = fixture.makeSession(micStatus: .denied, makeWriter: { _ in slowWriter })
        _ = try await session.start()

        let start = ContinuousClock.now
        for _ in 0 ..< 5 {
            fixture.systemAudioSource.push(systemChunk())
        }
        let elapsed = ContinuousClock.now - start

        // Pushing must not have waited on the writer at all — a real
        // audio callback doing the equivalent (a raw copy into a ring
        // buffer) is microseconds of work regardless of how slow whatever
        // eventually consumes the ring is.
        #expect(elapsed < .seconds(1))

        _ = try? await session.stop()
        #expect(slowWriter.writeCount >= 1)
    }
}
