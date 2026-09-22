import AudioToolbox
import AVFoundation
import Core
import CoreAudio
import Dispatch
import Foundation

/// Story 5.2's "30 consecutive zero seconds of system audio ⇒ rebuild, at
/// most once per 30s" rule, as pure decision logic — kept separate from
/// `ProcessTapSource` itself so `ProcessTapSourceTests` can drive it
/// directly with synthetic durations, since a real Core Audio tap needs a
/// live Mac to exercise. A zero-buffer stretch is ambiguous with a quiet
/// meeting or a missing grant (research.md); this never fails the capture,
/// it only decides when a rebuild is due.
struct ZeroBufferWatchdog: Sendable, Equatable {
    static let rebuildThreshold: Double = 30

    private(set) var exactZeroSeconds: Double = 0
    private(set) var rebuildCount: Int = 0
    private var consecutiveZeroSeconds: Double = 0

    /// `duration` is the wall-clock length of the buffer just observed;
    /// `isExactZero` is whether every sample in it was exactly zero.
    /// Returns whether a rebuild is due right now — true only the instant
    /// the running zero streak crosses the threshold, and the streak resets
    /// immediately after so the next rebuild needs its own fresh 30
    /// consecutive seconds.
    mutating func observe(isExactZero: Bool, duration: Double) -> Bool {
        guard isExactZero else {
            consecutiveZeroSeconds = 0
            return false
        }
        consecutiveZeroSeconds += duration
        exactZeroSeconds += duration
        guard consecutiveZeroSeconds >= Self.rebuildThreshold else { return false }
        consecutiveZeroSeconds = 0
        rebuildCount += 1
        return true
    }
}

/// Whether every sample in a buffer is exactly zero — the shape both a
/// missing System Audio Recording grant and a genuinely silent stretch of
/// the meeting produce (research.md's "any-zero-buffer ambiguity"), which is
/// exactly why `ZeroBufferWatchdog` treats it as a rebuild trigger rather
/// than a failure.
enum ZeroBufferDetector {
    static func isExactZero(_ buffer: AVAudioPCMBuffer) -> Bool {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return true }
        guard let channelData = buffer.floatChannelData else { return true }
        for channel in 0 ..< Int(buffer.format.channelCount) {
            let samples = channelData[channel]
            for frame in 0 ..< frameCount where samples[frame] != 0 {
                return false
            }
        }
        return true
    }
}

/// The one `SystemAudioSource` conformance (Decision 1.4): a Core Audio
/// global process tap, excluding auricle's own process, mixed to mono in a
/// private aggregate device and read through an `AudioDeviceIOProc`
/// (research.md candidate B — narrower TCC grant and no reported recurring
/// prompt, versus ScreenCaptureKit's full Screen Recording grant). The
/// 14.4 floor is `AudioHardwareCreateProcessTap`'s own minimum.
///
/// `@unchecked Sendable`: every mutable field is touched only while `lock`
/// is held, including from the IOProc's own dispatch queue, which runs
/// independently of whatever thread called `start()`/`stop()`.
@available(macOS 14.4, *)
public final class ProcessTapSource: SystemAudioSource, @unchecked Sendable {
    private static let log = Log(category: "process-tap-source")

    private struct ActiveHandles {
        let tapID: AudioObjectID
        let aggregateDeviceID: AudioObjectID
        let ioProcID: AudioDeviceIOProcID
        let format: AVAudioFormat
    }

    private let lock = NSLock()
    private var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var activeHandles: ActiveHandles?
    private var watchdog = ZeroBufferWatchdog()
    private var isStopped = false

    public init() {}

    public var watchdogStats: SystemAudioWatchdogStats {
        lock.lock()
        defer { lock.unlock() }
        return SystemAudioWatchdogStats(exactZeroSeconds: watchdog.exactZeroSeconds, rebuildCount: watchdog.rebuildCount)
    }

    public func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        lock.lock()
        guard self.onBuffer == nil, !isStopped else {
            lock.unlock()
            throw CaptureError.streamInterrupted(reason: "ProcessTapSource.start() called more than once")
        }
        self.onBuffer = onBuffer
        lock.unlock()
        do {
            try buildAndStart()
        } catch {
            // Otherwise a failed build leaves `onBuffer` permanently
            // non-nil, so every later `start()` on this instance throws
            // "already called" even though no tap ever actually ran.
            lock.lock()
            self.onBuffer = nil
            lock.unlock()
            throw error
        }
    }

    public func stop() {
        lock.lock()
        let handles = activeHandles
        activeHandles = nil
        onBuffer = nil
        isStopped = true
        lock.unlock()
        if let handles {
            Self.tearDown(handles)
        }
    }

    // MARK: - Setup / teardown

    /// Builds a fresh tap, aggregate device and IOProc and starts it —
    /// used by both `start()` and the watchdog rebuild path, since a
    /// rebuild is exactly "tear down, then run this again."
    private func buildAndStart() throws {
        lock.lock()
        let alreadyStopped = isStopped
        lock.unlock()
        guard !alreadyStopped else { return }

        let ownProcessObjectID = try Self.processObjectID(forPID: ProcessInfo.processInfo.processIdentifier)
        let tapDescription = CATapDescription(monoGlobalTapButExcludeProcesses: [ownProcessObjectID])
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        var tapID: AudioObjectID = 0
        try Self.check(AudioHardwareCreateProcessTap(tapDescription, &tapID), "AudioHardwareCreateProcessTap")

        do {
            let format = try Self.tapFormat(for: tapID)
            let aggregateDeviceID = try Self.createAggregateDevice(tapUID: tapDescription.uuid.uuidString)
            do {
                let ioProcID = try startIOProc(aggregateDeviceID: aggregateDeviceID, format: format)
                installActiveHandles(tapID: tapID, aggregateDeviceID: aggregateDeviceID, ioProcID: ioProcID, format: format)
            } catch {
                AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
                throw error
            }
        } catch {
            AudioHardwareDestroyProcessTap(tapID)
            throw error
        }
    }

    /// A private, tap-only aggregate device — no real hardware sub-devices,
    /// since the whole point is IO from the tap alone.
    private static func createAggregateDevice(tapUID: String) throws -> AudioObjectID {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "auricle-system-audio-tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID]],
        ]
        var aggregateDeviceID: AudioObjectID = 0
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateDeviceID)
        try check(status, "AudioHardwareCreateAggregateDevice")
        return aggregateDeviceID
    }

    /// Registers the IOProc and starts the device, tearing the IOProc back
    /// down (but not the aggregate device — the caller owns that) if
    /// `AudioDeviceStart` fails after registration already succeeded.
    private func startIOProc(aggregateDeviceID: AudioObjectID, format: AVAudioFormat) throws -> AudioDeviceIOProcID {
        var ioProcID: AudioDeviceIOProcID?
        let queue = DispatchQueue(label: "com.auricle.capture.process-tap")
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateDeviceID, queue) { [weak self] _, inInputData, _, _, _ in
            self?.handleInput(inInputData, format: format)
        }
        guard createStatus == noErr, let ioProcID else {
            throw CaptureError.streamInterrupted(reason: "AudioDeviceCreateIOProcIDWithBlock failed (OSStatus \(createStatus))")
        }

        let startStatus = AudioDeviceStart(aggregateDeviceID, ioProcID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            throw CaptureError.streamInterrupted(reason: "AudioDeviceStart failed (OSStatus \(startStatus))")
        }
        return ioProcID
    }

    /// Installs the freshly built handles — unless `stop()` raced ahead of
    /// this build, in which case the new handles are torn back down
    /// immediately instead of resurrecting a source told to stop.
    private func installActiveHandles(tapID: AudioObjectID, aggregateDeviceID: AudioObjectID, ioProcID: AudioDeviceIOProcID, format: AVAudioFormat) {
        let handles = ActiveHandles(tapID: tapID, aggregateDeviceID: aggregateDeviceID, ioProcID: ioProcID, format: format)
        lock.lock()
        let stoppedWhileBuilding = isStopped
        if !stoppedWhileBuilding {
            activeHandles = handles
        }
        lock.unlock()
        if stoppedWhileBuilding {
            Self.tearDown(handles)
        }
    }

    /// Tears down one full tap/aggregate/IOProc triple. A free function
    /// rather than an instance method: it must run on handles this instance
    /// no longer holds a reference to once a rebuild has already installed
    /// new ones.
    private static func tearDown(_ handles: ActiveHandles) {
        AudioDeviceStop(handles.aggregateDeviceID, handles.ioProcID)
        AudioDeviceDestroyIOProcID(handles.aggregateDeviceID, handles.ioProcID)
        AudioHardwareDestroyAggregateDevice(handles.aggregateDeviceID)
        AudioHardwareDestroyProcessTap(handles.tapID)
    }

    /// Runs off the IOProc's own queue (not inline in the callback that
    /// triggered it) so tearing down the device that just called us never
    /// races with that same call still unwinding.
    private func rebuild() {
        lock.lock()
        let previous = activeHandles
        activeHandles = nil
        let alreadyStopped = isStopped
        lock.unlock()
        guard !alreadyStopped else { return }

        if let previous {
            Self.tearDown(previous)
        }
        do {
            try buildAndStart()
        } catch {
            Self.log.error("system audio tap rebuild failed", ["reason": .sensitive(String(describing: error))])
        }
    }

    // MARK: - IOProc callback

    private func handleInput(_ inputData: UnsafePointer<AudioBufferList>, format: AVAudioFormat) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData) else {
            Self.log.error("system audio buffer dropped: could not wrap IOProc input as AVAudioPCMBuffer")
            return
        }
        let duration = format.sampleRate > 0 ? Double(buffer.frameLength) / format.sampleRate : 0
        let isZero = ZeroBufferDetector.isExactZero(buffer)

        lock.lock()
        let shouldRebuild = watchdog.observe(isExactZero: isZero, duration: duration)
        let callback = onBuffer
        lock.unlock()

        callback?(buffer)
        if shouldRebuild {
            DispatchQueue.global(qos: .utility).async { [weak self] in self?.rebuild() }
        }
    }

    // MARK: - Core Audio helpers

    private static func check(_ status: OSStatus, _ context: String) throws {
        guard status == noErr else {
            throw CaptureError.streamInterrupted(reason: "\(context) failed (OSStatus \(status))")
        }
    }

    /// Resolves auricle's own PID to the Process object Core Audio expects
    /// in `CATapDescription`'s exclude list — there is no simpler way to
    /// name "the current process" to this API.
    private static func processObjectID(forPID pid: pid_t) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        var qualifierPID = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &qualifierPID,
            &dataSize,
            &objectID,
        )
        try check(status, "kAudioHardwarePropertyTranslatePIDToProcessObject")
        guard objectID != kAudioObjectUnknown else {
            throw CaptureError.streamInterrupted(reason: "the system has no Process object for auricle's own PID")
        }
        return objectID
    }

    /// The tap's actual stream format — mono at whatever rate the system
    /// mix currently runs at, per research.md ("a tap offers mono or
    /// stereo mixdown but no sample-rate option"). `AudioMixer` is what
    /// resamples this to 16 kHz.
    private static func tapFormat(for tapID: AudioObjectID) throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        var asbd = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &dataSize, &asbd)
        try check(status, "kAudioTapPropertyFormat")
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw CaptureError.streamInterrupted(reason: "the tap's audio format could not be represented as an AVAudioFormat")
        }
        return format
    }
}
