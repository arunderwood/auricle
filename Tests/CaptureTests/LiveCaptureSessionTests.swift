@testable import Capture
import Core
import Foundation
import Permissions
import Testing
import TestSupport

/// Reports `.denied` for the microphone, so `CaptureSession` never starts the
/// real engine and no test needs audio hardware.
private func deniedMicrophoneChecker() -> FakePermissionChecker {
    FakePermissionChecker(
        checkResult: .unknown,
        requestResult: .unknown,
        checkResults: [.microphone: .denied],
        requestResults: [.microphone: .denied],
    )
}

private struct SourceFailure: Error, CustomStringConvertible {
    var description: String {
        "tap gone"
    }
}

private final class FailingSource: SystemAudioSource, @unchecked Sendable {
    private let lock = NSLock()
    private let failStart: Bool
    private let failRebuild: Bool
    private var rebuilds = 0

    init(failStart: Bool = false, failRebuild: Bool = false) {
        self.failStart = failStart
        self.failRebuild = failRebuild
    }

    var rebuildCount: Int {
        lock.withLock { rebuilds }
    }

    func start() throws {
        if failStart {
            throw SourceFailure()
        }
    }

    func stop() {}

    func drain(_: (RawAudioChunk) -> Void) {}

    var ringLossStats: RingLossStats {
        RingLossStats()
    }

    func rebuild() throws {
        lock.withLock { rebuilds += 1 }
        if failRebuild {
            throw SourceFailure()
        }
    }
}

private func makeSession(source: FailingSource, root: URL) -> LiveCaptureSession {
    LiveCaptureSession(
        meetingID: .generate(),
        permissionChecker: deniedMicrophoneChecker(),
        cacheDirectory: { root.appendingPathComponent($0.rawValue, isDirectory: true) },
        systemAudioSource: source,
    )
}

private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("auricle-live-session-tests-\(UUID().uuidString)", isDirectory: true)
}

/// Every fault the session reported. `stop()` finishes the stream, so this
/// returns once the session is stopped.
private func collectFaults(_ session: LiveCaptureSession) async -> [CaptureStreamFault] {
    _ = try? await session.stop()
    var faults: [CaptureStreamFault] = []
    for await fault in session.faults {
        faults.append(fault)
    }
    return faults
}

@Test func aSystemAudioSourceThatFailsToStartReportsOneTransientFault() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = makeSession(source: FailingSource(failStart: true), root: root)

    await #expect(throws: SourceFailure.self) {
        _ = try await session.start()
    }

    #expect(await collectFaults(session) == [.transient(.systemAudio, reason: "tap gone")])
}

@Test func restartingTheMicrophoneWhenItIsDeniedIsARevocation() async {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = makeSession(source: FailingSource(), root: root)

    do {
        try await session.restart(.microphone)
        Issue.record("expected restart(.microphone) to throw")
    } catch CaptureError.permissionRevokedMidstream {
        // The expected outcome.
    } catch {
        Issue.record("expected permissionRevokedMidstream, got \(error)")
    }
}

/// The error reaches the caller once: as the thrown error, not also as a fault.
@Test func aSystemAudioRestartThatThrowsRethrowsWithoutReportingAFault() async {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = FailingSource(failRebuild: true)
    let session = makeSession(source: source, root: root)

    await #expect(throws: SourceFailure.self) {
        try await session.restart(.systemAudio)
    }

    #expect(source.rebuildCount == 1)
    #expect(await collectFaults(session).isEmpty)
}

@Test func aRestartAfterStopLeavesTheSourceAlone() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = FailingSource()
    let session = makeSession(source: source, root: root)
    _ = try await session.start()
    _ = try await session.stop()

    try await session.restart(.systemAudio)

    #expect(source.rebuildCount == 0)
}

// MARK: - Configuration-change classification

@Test func aConfigurationChangeThatStopsTheEngineWithTheMicrophoneDeniedIsARevocation() async {
    let checker = FakePermissionChecker(checkResults: [.microphone: .denied])

    let fault = await LiveCaptureSession.configurationChangeFault(engineRunning: false, micIncluded: true, observing: true, checker: checker)

    #expect(fault == .permissionRevoked(.microphone))
    // A refreshed answer, not the memo from when the capture started.
    #expect(checker.calls == [.refresh, .check(.microphone)])
}

@Test(arguments: [PermissionStatus.granted, .notDetermined, .unknown])
func aConfigurationChangeThatStopsTheEngineWithTheMicrophoneNotDeniedIsTransient(status: PermissionStatus) async {
    let checker = FakePermissionChecker(checkResults: [.microphone: status])

    let fault = await LiveCaptureSession.configurationChangeFault(engineRunning: false, micIncluded: true, observing: true, checker: checker)

    #expect(fault == .transient(.microphone, reason: "microphone engine stopped after a configuration change"))
}

@Test(arguments: [
    (engineRunning: true, micIncluded: true, observing: true),
    (engineRunning: false, micIncluded: false, observing: true),
    (engineRunning: false, micIncluded: true, observing: false),
])
func aConfigurationChangeTheCaptureRodeOutIsNoFault(engineRunning: Bool, micIncluded: Bool, observing: Bool) async {
    let checker = FakePermissionChecker(checkResults: [.microphone: .denied])

    let fault = await LiveCaptureSession.configurationChangeFault(
        engineRunning: engineRunning,
        micIncluded: micIncluded,
        observing: observing,
        checker: checker,
    )

    #expect(fault == nil)
    #expect(checker.calls.isEmpty)
}
