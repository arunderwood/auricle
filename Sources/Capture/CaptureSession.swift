import AVFoundation
import Core
import Foundation
import Permissions

/// Whether the microphone ended up in the mix. `false` only when
/// `PermissionChecker.check(.microphone)` reports `.denied` at `start()` —
/// every other status (`.granted`, `.notDetermined`, `.unknown`) still
/// tries the mic, since a missing or undetermined answer is not the same
/// as a denial (AC's mic-denied scenario is specifically about `.denied`).
public struct CaptureSessionStartResult: Sendable, Equatable {
    public let micIncluded: Bool
}

/// Wires the microphone (`AVAudioEngine`) and system audio
/// (`SystemAudioSource`) through `AudioMixer` into `WAVWriter` — Decision
/// 1.4's capture format, mono 16 kHz PCM16. One instance captures one
/// meeting once: `start()` past the first call throws rather than
/// silently reusing engine/tap state that a prior `stop()` already tore
/// down.
///
/// `@unchecked Sendable`: every mutable field is touched only while `lock`
/// (state) or `writeLock` (the mixer/writer pipeline) is held, which is
/// what lets the mic-tap callback and the system-tap callback — each on
/// their own thread — drive the same `AudioMixer`/`WAVWriter` safely.
@available(macOS 14.4, *)
public final class CaptureSession: @unchecked Sendable {
    private static let log = Log(category: "capture-session")

    private let meetingID: MeetingID
    private let engine: AVAudioEngine
    private let systemAudioSource: SystemAudioSource
    private let permissionChecker: PermissionChecking
    private let cacheDirectory: @Sendable (MeetingID) throws -> URL
    /// Test seam: production always calls `AVAudioEngine.start()`, but a
    /// concrete `AVAudioEngine` can't otherwise be made to fail
    /// deterministically without real audio hardware.
    private let startEngine: @Sendable (AVAudioEngine) throws -> Void

    private enum Phase: Equatable {
        case idle
        /// Reserved atomically by `start()` before any async work begins,
        /// so two concurrent `start()` calls can't both pass the `.idle`
        /// guard and both stand up a tap/engine/writer.
        case starting
        case running
        /// Reserved atomically by `stop()` before releasing the lock for
        /// teardown, so two concurrent `stop()` calls can't both observe
        /// `.running` and both run the full teardown/flush/finalize path.
        case stopping
        case stopped(path: String)
        /// A terminal state for a `stop()` that threw partway through
        /// teardown — a retried `stop()` re-throws this instead of redoing
        /// `systemAudioSource.stop()`/`stopMicInput()`/`finalize()`.
        case stopFailed(reason: String)
    }

    private let lock = NSLock()
    private var phase: Phase = .idle
    private var mixer: AudioMixer?
    private var writer: WAVWriter?
    private var micIncluded = false

    /// Serializes the ingest-mix-write sequence across both callback
    /// threads, so a mic buffer and a system buffer arriving at the same
    /// moment can never interleave their writes to `WAVWriter` out of
    /// order.
    private let writeLock = NSLock()

    public init(
        meetingID: MeetingID,
        engine: AVAudioEngine = AVAudioEngine(),
        systemAudioSource: SystemAudioSource = ProcessTapSource(),
        permissionChecker: PermissionChecking = PermissionChecker(),
        cacheDirectory: @escaping @Sendable (MeetingID) throws -> URL = { try CacheArtifactWriter.cacheDirectory(for: $0) },
        startEngine: @escaping @Sendable (AVAudioEngine) throws -> Void = { try $0.start() },
    ) {
        self.meetingID = meetingID
        self.engine = engine
        self.systemAudioSource = systemAudioSource
        self.permissionChecker = permissionChecker
        self.cacheDirectory = cacheDirectory
        self.startEngine = startEngine
    }

    /// Starts system audio unconditionally and the microphone unless
    /// `PermissionChecker.check(.microphone)` reports `.denied`.
    public func start() async throws -> CaptureSessionStartResult {
        try lock.withLock {
            guard phase == .idle else {
                throw CaptureError.streamInterrupted(reason: "CaptureSession is single-use; start() was already called")
            }
            phase = .starting
        }

        let micStatus = await permissionChecker.check(.microphone)
        let includeMic = micStatus != .denied
        let mixer = AudioMixer()

        try systemAudioSource.start { [weak self] buffer in
            self?.ingest(systemBuffer: buffer)
        }

        if includeMic {
            do {
                try startMicInput()
            } catch {
                systemAudioSource.stop()
                throw error
            }
        }

        let writer: WAVWriter
        do {
            writer = try WAVWriter(meetingID: meetingID, cacheDirectory: cacheDirectory)
        } catch {
            if includeMic {
                stopMicInput()
            }
            systemAudioSource.stop()
            throw error
        }

        lock.withLock {
            self.mixer = mixer
            self.writer = writer
            micIncluded = includeMic
            phase = .running
        }

        return CaptureSessionStartResult(micIncluded: includeMic)
    }

    /// Flushes both sources and finalizes `audio.wav`, returning its path.
    /// Idempotent per NFR-R5: a second call, or a call before `start()`,
    /// never touches an already-torn-down engine/tap twice. `phase` always
    /// lands on a terminal state before this returns or throws — including
    /// on a mid-teardown failure — so a retried `stop()` never repeats
    /// `systemAudioSource.stop()`/`stopMicInput()`/`finalize()`.
    @discardableResult
    public func stop() throws -> URL {
        lock.lock()
        switch phase {
        case .idle, .starting:
            lock.unlock()
            throw CaptureError.streamInterrupted(reason: "CaptureSession.stop() called before start() completed")
        case .stopping:
            lock.unlock()
            throw CaptureError.streamInterrupted(reason: "CaptureSession.stop() is already in progress")
        case let .stopped(path):
            lock.unlock()
            return URL(fileURLWithPath: path)
        case let .stopFailed(reason):
            lock.unlock()
            throw CaptureError.streamInterrupted(reason: reason)
        case .running:
            phase = .stopping
        }
        let mixer = mixer
        let writer = writer
        let includeMic = micIncluded
        lock.unlock()

        do {
            systemAudioSource.stop()
            if includeMic {
                stopMicInput()
            }

            writeLock.lock()
            defer { writeLock.unlock() }
            if let mixer, let writer {
                let remaining = mixer.peekFlush()
                if !remaining.isEmpty {
                    try writer.write(remaining)
                    mixer.discardFlushed()
                }
            }
            try writer?.finalize()

            let url = try cacheDirectory(meetingID).appendingPathComponent(AudioImporter.audioFileName)
            lock.withLock { phase = .stopped(path: url.path) }
            return url
        } catch {
            let reason = String(describing: error)
            lock.withLock { phase = .stopFailed(reason: reason) }
            throw error
        }
    }

    // MARK: - Microphone

    private func startMicInput() throws {
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            self?.ingest(micBuffer: buffer)
        }
        do {
            try startEngine(engine)
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.streamInterrupted(reason: "microphone engine failed to start: \(error.localizedDescription)")
        }
    }

    private func stopMicInput() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }

    // MARK: - Ingest

    private func ingest(systemBuffer buffer: AVAudioPCMBuffer) {
        guard let (mixer, writer) = runningComponents() else {
            Self.log.error("system audio buffer dropped: session is not running")
            return
        }
        writeLock.lock()
        defer { writeLock.unlock() }
        do {
            try mixer.ingestSystem(buffer)
            let pcm = mixer.drain()
            if !pcm.isEmpty {
                try writer.write(pcm)
            }
        } catch {
            Self.log.error("system audio buffer dropped", ["reason": .sensitive(String(describing: error))])
        }
    }

    private func ingest(micBuffer buffer: AVAudioPCMBuffer) {
        guard let (mixer, writer) = runningComponents() else {
            Self.log.error("mic audio buffer dropped: session is not running")
            return
        }
        writeLock.lock()
        defer { writeLock.unlock() }
        do {
            try mixer.ingestMic(buffer)
            let pcm = mixer.drain()
            if !pcm.isEmpty {
                try writer.write(pcm)
            }
        } catch {
            Self.log.error("mic audio buffer dropped", ["reason": .sensitive(String(describing: error))])
        }
    }

    private func runningComponents() -> (AudioMixer, WAVWriter)? {
        lock.lock()
        defer { lock.unlock() }
        guard case .running = phase, let mixer, let writer else { return nil }
        return (mixer, writer)
    }
}

/// Story 5.8's onboarding trigger: there is no public API to check or
/// request the "System Audio Recording" TCC grant (research.md), so the
/// only way to surface the OS's prompt is to actually run a tap briefly.
@available(macOS 14.4, *)
public enum SystemAudioPermissionProbe {
    /// Runs `source` for one second and discards every buffer — purely so
    /// macOS shows the System Audio Recording prompt the first time this
    /// runs, for onboarding to trigger ahead of the first real capture.
    public static func prompt(source: SystemAudioSource = ProcessTapSource()) async throws {
        try source.start(onBuffer: { _ in })
        defer { source.stop() }
        try await Task.sleep(for: .seconds(1))
    }
}
