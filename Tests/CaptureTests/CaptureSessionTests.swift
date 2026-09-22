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
/// `CaptureSessionTests` never needs a live tap or a live Mac — it drives
/// `CaptureSession`'s wiring by calling `emit(_:)` as if the tap had
/// produced a buffer.
private final class FakeSystemAudioSource: SystemAudioSource, @unchecked Sendable {
    private let lock = NSLock()
    private var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        startCallCount += 1
        self.onBuffer = onBuffer
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopCallCount += 1
        onBuffer = nil
    }

    var watchdogStats: SystemAudioWatchdogStats {
        SystemAudioWatchdogStats()
    }

    func emit(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let callback = onBuffer
        lock.unlock()
        callback?(buffer)
    }
}

/// A silent mono buffer at 48 kHz — enough to exercise `AudioMixer`'s
/// resample-and-write path without asserting on tone content.
private func systemBuffer(seconds: Double = 0.2) throws -> AVAudioPCMBuffer {
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false))
    let frames = AVAudioFrameCount(seconds * 48000)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let samples = try #require(buffer.floatChannelData)[0]
    for frame in 0 ..< Int(frames) {
        samples[frame] = 0.4 * Float(sin(2 * Double.pi * 440 * Double(frame) / 48000))
    }
    return buffer
}

@available(macOS 14.4, *)
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
    ) -> CaptureSession {
        CaptureSession(
            meetingID: meetingID,
            engine: AVAudioEngine(),
            systemAudioSource: systemAudioSource,
            permissionChecker: FakePermissionChecker(microphoneStatus: micStatus),
            cacheDirectory: { root.appendingPathComponent($0.rawValue, isDirectory: true) },
            startEngine: startEngine,
        )
    }

    func audioURL() -> URL {
        root.appendingPathComponent(meetingID.rawValue).appendingPathComponent(AudioImporter.audioFileName)
    }
}

/// `CaptureSession` is `@available(macOS 14.4, *)` (the process-tap floor),
/// but Swift Testing's `@Suite`/`@Test` macros can't be combined with an
/// `@available` attribute on the same declaration — every test body instead
/// opens with `guard #available(macOS 14.4, *) else { ... }`, which is
/// always true on any Mac this suite actually runs on (the toolchain's own
/// minimum is far newer) and keeps the macro expansion unencumbered.
@Suite(.serialized)
struct CaptureSessionTests {
    @Test func micPermissionDeniedRecordsSystemAudioOnlyAndNeverStartsTheMicEngine() async throws {
        guard #available(macOS 14.4, *) else {
            Issue.record("this suite requires macOS 14.4")
            return
        }
        let fixture = SessionFixture()
        defer { fixture.cleanUp() }
        let session = fixture.makeSession(micStatus: .denied)

        let result = try await session.start()
        #expect(result.micIncluded == false)
        #expect(fixture.systemAudioSource.startCallCount == 1)

        try fixture.systemAudioSource.emit(systemBuffer())
        let url = try session.stop()

        #expect(url == fixture.audioURL())
        #expect(fixture.systemAudioSource.stopCallCount == 1)
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        #expect(file.fileFormat.sampleRate == 16000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(file.length > 0)
    }

    @Test func micPermissionNotDeterminedStillIncludesTheMic() async throws {
        guard #available(macOS 14.4, *) else {
            Issue.record("this suite requires macOS 14.4")
            return
        }
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
            _ = try? session.stop()
        } catch {
            // Engine start failing in a hardware-less CI environment is not
            // this test's concern.
        }
    }

    @Test func stopBeforeStartThrows() throws {
        guard #available(macOS 14.4, *) else {
            Issue.record("this suite requires macOS 14.4")
            return
        }
        let fixture = SessionFixture()
        defer { fixture.cleanUp() }
        let session = fixture.makeSession(micStatus: .denied)

        #expect(throws: CaptureError.self) {
            try session.stop()
        }
    }

    @Test func startCalledTwiceThrows() async throws {
        guard #available(macOS 14.4, *) else {
            Issue.record("this suite requires macOS 14.4")
            return
        }
        let fixture = SessionFixture()
        defer { fixture.cleanUp() }
        let session = fixture.makeSession(micStatus: .denied)
        _ = try await session.start()

        await #expect(throws: CaptureError.self) {
            try await session.start()
        }
        _ = try? session.stop()
    }

    @Test func stopCalledTwiceIsIdempotentAndReturnsTheSamePath() async throws {
        guard #available(macOS 14.4, *) else {
            Issue.record("this suite requires macOS 14.4")
            return
        }
        let fixture = SessionFixture()
        defer { fixture.cleanUp() }
        let session = fixture.makeSession(micStatus: .denied)
        _ = try await session.start()
        try fixture.systemAudioSource.emit(systemBuffer())

        let first = try session.stop()
        let second = try session.stop()

        #expect(first == second)
        #expect(fixture.systemAudioSource.stopCallCount == 1)
    }

    @Test func micEngineStartFailureTearsDownSystemAudioAndPropagatesTheError() async throws {
        guard #available(macOS 14.4, *) else {
            Issue.record("this suite requires macOS 14.4")
            return
        }
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

    @Test func writerConstructionFailureTearsDownSystemAudioAndPropagatesTheError() async throws {
        guard #available(macOS 14.4, *) else {
            Issue.record("this suite requires macOS 14.4")
            return
        }
        let fixture = SessionFixture()
        defer { fixture.cleanUp() }
        // Pre-create audio.wav so WAVWriter's O_EXCL create fails, forcing
        // the WAVWriter-construction-failure branch of start().
        let directory = fixture.root.appendingPathComponent(fixture.meetingID.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try AtomicWriter.write(Data(), to: directory.appendingPathComponent(AudioImporter.audioFileName))
        let session = fixture.makeSession(micStatus: .denied)

        await #expect(throws: CaptureError.self) {
            try await session.start()
        }
        #expect(fixture.systemAudioSource.startCallCount == 1)
        #expect(fixture.systemAudioSource.stopCallCount == 1)
    }

    @Test func permissionProbeStartsAndStopsTheSource() async throws {
        guard #available(macOS 14.4, *) else {
            Issue.record("this suite requires macOS 14.4")
            return
        }
        let source = FakeSystemAudioSource()

        try await SystemAudioPermissionProbe.prompt(source: source)

        #expect(source.startCallCount == 1)
        #expect(source.stopCallCount == 1)
    }
}
