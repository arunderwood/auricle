import AVFoundation
import Core
import Foundation
import Permissions

/// One meeting's recording, as `CaptureStage` drives it: start, stop, restart
/// an input after a transient fault, and report faults as they happen. A seam
/// so the stage's state handling is testable without audio hardware.
public protocol CaptureRecording: Sendable {
    func start() async throws -> CaptureSessionStartResult
    /// Finalizes the WAV and returns its URL. Safe to call after a fault has
    /// already stopped an input: the partial audio is still finalized.
    func stop() async throws -> URL
    /// Brings `source` back after a transient fault. Throws
    /// `CaptureError.permissionRevokedMidstream` when the microphone turns out
    /// to be denied.
    func restart(_ source: CaptureSource) async throws
    var watchdogStats: CaptureWatchdogStats { get }
    /// Every fault either input reports while recording. Finishes on `stop()`.
    var faults: AsyncStream<CaptureStreamFault> { get }
}

/// The production `CaptureRecording`: a `CaptureSession` built on an
/// `AVAudioEngine` and a fault-reporting process tap that this type keeps
/// references to, so it can observe and restart both without reaching into
/// the session.
///
/// A microphone fault is seen through `AVAudioEngineConfigurationChange`: the
/// engine posts it when its input or output changes, and stops itself if it
/// cannot carry on. After one, an engine that is no longer running is a
/// revocation when a refreshed check reports the microphone `.denied`, and a
/// transient fault otherwise.
///
/// `@unchecked Sendable`: `observer`, `micIncluded` and `stopped` are guarded
/// by `lock`. `engine` is not: `CaptureSession` starts and stops it, the
/// configuration-change handler reads `isRunning` on whatever thread posted
/// the notification, and `restart` starts it again. That relies on
/// `AVAudioEngine` tolerating those calls from different threads; it gives no
/// documented guarantee. What this type does ensure is that `restart` never
/// touches the engine or the source once `stop()` has begun.
public final class LiveCaptureSession: CaptureRecording, @unchecked Sendable {
    public let faults: AsyncStream<CaptureStreamFault>

    private let engine: AVAudioEngine
    private let systemAudioSource: any SystemAudioSource
    private let permissionChecker: any PermissionChecking
    private let session: CaptureSession
    private let continuation: AsyncStream<CaptureStreamFault>.Continuation

    private let lock = NSLock()
    private var observer: (any NSObjectProtocol)?
    private var micIncluded = false
    private var stopped = false

    public init(
        meetingID: MeetingID,
        permissionChecker: any PermissionChecking = PermissionChecker(),
        cacheDirectory: @escaping @Sendable (MeetingID) throws -> URL = { try CacheArtifactWriter.cacheDirectory(for: $0) },
        systemAudioSource: any SystemAudioSource = ProcessTapSource(),
    ) {
        let (faults, continuation) = AsyncStream<CaptureStreamFault>.makeStream()
        let engine = AVAudioEngine()
        let reporting = FaultReportingSystemAudioSource(wrapping: systemAudioSource) { continuation.yield($0) }
        self.faults = faults
        self.continuation = continuation
        self.engine = engine
        self.systemAudioSource = systemAudioSource
        self.permissionChecker = permissionChecker
        session = CaptureSession(
            meetingID: meetingID,
            engine: engine,
            systemAudioSource: reporting,
            permissionChecker: permissionChecker,
            cacheDirectory: cacheDirectory,
        )
    }

    public var watchdogStats: CaptureWatchdogStats {
        session.watchdogStats
    }

    public func start() async throws -> CaptureSessionStartResult {
        let result = try await session.start()
        let token = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil,
        ) { [weak self] _ in
            self?.engineConfigurationChanged()
        }
        lock.withLock {
            micIncluded = result.micIncluded
            observer = token
        }
        return result
    }

    public func stop() async throws -> URL {
        let token = lock.withLock {
            stopped = true
            defer { observer = nil }
            return observer
        }
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
        continuation.finish()
        return try await session.stop()
    }

    /// A no-op once `stop()` has begun: a restart that raced the stop must not
    /// bring an input back on a finished capture.
    public func restart(_ source: CaptureSource) async throws {
        guard !lock.withLock({ stopped }) else { return }
        switch source {
        case .microphone:
            await permissionChecker.refresh()
            if await permissionChecker.check(.microphone) == .denied {
                throw CaptureError.permissionRevokedMidstream
            }
            guard !lock.withLock({ stopped }) else { return }
            do {
                engine.prepare()
                try engine.start()
            } catch {
                throw CaptureError.streamInterrupted(reason: "microphone engine failed to restart: \(error.localizedDescription)")
            }
        case .systemAudio:
            // The undecorated source: a throw here reaches `CaptureStage` as
            // this call's error, and must not also arrive as a second fault.
            try systemAudioSource.rebuild()
        }
    }

    /// A configuration change on an engine the microphone never started is
    /// not a microphone fault, and neither is one the engine rode out.
    private func engineConfigurationChanged() {
        guard lock.withLock({ micIncluded && observer != nil }), !engine.isRunning else { return }
        let checker = permissionChecker
        let continuation = continuation
        Task {
            await checker.refresh()
            let status = await checker.check(.microphone)
            continuation.yield(
                status == .denied
                    ? .permissionRevoked(.microphone)
                    : .transient(.microphone, reason: "microphone engine stopped after a configuration change"),
            )
        }
    }
}
