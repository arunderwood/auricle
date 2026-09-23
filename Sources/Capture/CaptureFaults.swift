import Foundation

/// The two inputs a capture mixes. The raw value is what `CaptureMeta.source`
/// records.
public enum CaptureSource: String, Sendable, Equatable {
    case microphone
    case systemAudio = "system_audio"
}

/// Something a live capture's inputs reported while recording.
///
/// `permissionRevoked` is only ever the microphone: it is the one input whose
/// grant a status read can confirm. A revoked System Audio grant delivers exact
/// zeros with no error, so it never reaches this type; every Core Audio error
/// is `transient`.
public enum CaptureStreamFault: Sendable, Equatable {
    case permissionRevoked(CaptureSource)
    case transient(CaptureSource, reason: String)

    public var source: CaptureSource {
        switch self {
        case let .permissionRevoked(source), let .transient(source, _):
            source
        }
    }
}

/// Wraps a `SystemAudioSource` so a thrown `start` or `rebuild` is reported
/// as a transient fault before it is rethrown. `CaptureSession`'s watchdog
/// calls `rebuild()` with `try?`, which would otherwise discard the error.
public final class FaultReportingSystemAudioSource: SystemAudioSource {
    private let wrapped: any SystemAudioSource
    private let report: @Sendable (CaptureStreamFault) -> Void

    public init(wrapping wrapped: any SystemAudioSource, report: @escaping @Sendable (CaptureStreamFault) -> Void) {
        self.wrapped = wrapped
        self.report = report
    }

    public func start() throws {
        do {
            try wrapped.start()
        } catch {
            report(.transient(.systemAudio, reason: String(describing: error)))
            throw error
        }
    }

    public func stop() {
        wrapped.stop()
    }

    public func drain(_ consume: (RawAudioChunk) -> Void) {
        wrapped.drain(consume)
    }

    public func rebuild() throws {
        do {
            try wrapped.rebuild()
        } catch {
            report(.transient(.systemAudio, reason: String(describing: error)))
            throw error
        }
    }
}

/// Decides whether a transient stream fault is restarted inline or fails the
/// capture: the third fault whose two predecessors both fall within the last
/// 30 seconds fails it. Faults older than the window are forgotten, so a long
/// meeting with an occasional hiccup never accumulates toward the cap.
public struct TransientRestartPolicy: Sendable, Equatable {
    public enum Decision: Sendable, Equatable {
        case restart
        case fail
    }

    public static let window: TimeInterval = 30
    public static let limit = 3

    private var recent: [Date] = []

    public init() {}

    public mutating func record(at now: Date) -> Decision {
        // An entry dated after `now` (the wall clock stepped back) is dropped
        // too, or it would sit inside the window indefinitely.
        recent = recent.filter { (0 ..< Self.window).contains(now.timeIntervalSince($0)) } + [now]
        return recent.count >= Self.limit ? .fail : .restart
    }
}
