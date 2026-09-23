@testable import Capture
import Foundation
import Testing

private struct SourceFailure: Error, CustomStringConvertible {
    var description: String {
        "tap gone"
    }
}

private final class ThrowingSource: SystemAudioSource, @unchecked Sendable {
    private let lock = NSLock()
    private var failing: Bool
    private(set) var stopCount = 0
    private(set) var drainCount = 0

    init(failing: Bool) {
        self.failing = failing
    }

    func start() throws {
        if lock.withLock({ failing }) {
            throw SourceFailure()
        }
    }

    func stop() {
        lock.withLock { stopCount += 1 }
    }

    func drain(_: (RawAudioChunk) -> Void) {
        lock.withLock { drainCount += 1 }
    }

    func rebuild() throws {
        if lock.withLock({ failing }) {
            throw SourceFailure()
        }
    }
}

private final class FaultLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [CaptureStreamFault] = []
    var faults: [CaptureStreamFault] {
        lock.withLock { stored }
    }

    func append(_ fault: CaptureStreamFault) {
        lock.withLock { stored.append(fault) }
    }
}

@Test func aThrowingStartOrRebuildIsReportedAsATransientSystemAudioFaultAndRethrown() {
    let log = FaultLog()
    let source = FaultReportingSystemAudioSource(wrapping: ThrowingSource(failing: true)) { log.append($0) }

    #expect(throws: SourceFailure.self) { try source.start() }
    #expect(throws: SourceFailure.self) { try source.rebuild() }
    #expect(log.faults == [
        .transient(.systemAudio, reason: "tap gone"),
        .transient(.systemAudio, reason: "tap gone"),
    ])
}

@Test func aSucceedingSourceReportsNothingAndEveryCallIsForwarded() throws {
    let log = FaultLog()
    let inner = ThrowingSource(failing: false)
    let source = FaultReportingSystemAudioSource(wrapping: inner) { log.append($0) }

    try source.start()
    try source.rebuild()
    source.drain { _ in }
    source.stop()

    #expect(log.faults.isEmpty)
    #expect(inner.stopCount == 1)
    #expect(inner.drainCount == 1)
}

@Test func twoFaultsInsideTheWindowRestartAndTheThirdFails() {
    var policy = TransientRestartPolicy()
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(policy.record(at: start) == .restart)
    #expect(policy.record(at: start.addingTimeInterval(10)) == .restart)
    #expect(policy.record(at: start.addingTimeInterval(29.9)) == .fail)
}

@Test func aThirdFaultAfterTheFirstLeftTheWindowRestarts() {
    var policy = TransientRestartPolicy()
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(policy.record(at: start) == .restart)
    #expect(policy.record(at: start.addingTimeInterval(20)) == .restart)
    #expect(policy.record(at: start.addingTimeInterval(30)) == .restart)
    #expect(policy.record(at: start.addingTimeInterval(49.9)) == .fail)
}

@Test func faultsSpacedWiderThanTheWindowNeverFail() {
    var policy = TransientRestartPolicy()
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    for index in 0 ..< 10 {
        #expect(policy.record(at: start.addingTimeInterval(Double(index) * 31)) == .restart)
    }
}

/// Faults dated after `now`, left by a wall clock that stepped back, drop out
/// of the window instead of counting toward the cap forever.
@Test func faultsFromBeforeABackwardClockJumpDoNotCountTowardTheCap() {
    var policy = TransientRestartPolicy()
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(policy.record(at: start) == .restart)
    #expect(policy.record(at: start.addingTimeInterval(5)) == .restart)
    #expect(policy.record(at: start.addingTimeInterval(-3600)) == .restart)
    #expect(policy.record(at: start.addingTimeInterval(-3590)) == .restart)
    #expect(policy.record(at: start.addingTimeInterval(-3585)) == .fail)
}
