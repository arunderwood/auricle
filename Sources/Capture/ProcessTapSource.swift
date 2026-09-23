import AudioToolbox
import AVFoundation
import Core
import CoreAudio
import Dispatch
import Foundation

/// The one `SystemAudioSource` conformance (Decision 1.4): a Core Audio
/// global process tap, excluding auricle's own process, mixed to mono in a
/// private aggregate device and read through an `AudioDeviceIOProc`
/// (research.md candidate B — narrower TCC grant and no reported recurring
/// prompt, versus ScreenCaptureKit's full Screen Recording grant). The
/// 14.4 floor is `AudioHardwareCreateProcessTap`'s own minimum.
///
/// The aggregate uses the default output device as its main/clock
/// sub-device, with drift compensation on the tap — matching
/// `insidegui/AudioCap` and Apple's own sample rather than a tap-only
/// aggregate, on the theory that a real clock source gives drift
/// compensation something to correct against. This is a judgment call:
/// it cannot be conclusively settled without the live-Mac check Story 5.6
/// runs.
///
/// The IOProc callback (`handleInput`) does the least possible work: a
/// bounds check and a raw-pointer copy into `ring`, nothing else — no
/// allocation, no locking beyond the ring's own bounded `os_unfair_lock`,
/// no I/O, no logging (NFR-P13). It runs directly on Core Audio's own I/O
/// thread (`AudioDeviceCreateIOProcIDWithBlock`'s dispatch queue is `nil`)
/// rather than being handed off to a queue, since the callback does only a
/// bounds check and a copy — nothing heavier needs to move off that
/// thread. Everything else — resampling, mixing, the watchdog,
/// `WAVWriter.write(_:)` — happens in whatever consumer calls `drain(_:)`,
/// which `CaptureSession` runs on a background `Task`.
///
/// `@unchecked Sendable`: every mutable field is either its own
/// thread-safe type (`ring`, `coordinator`) or touched only from within a
/// closure `coordinator` itself serializes. Every build/tear-down pass —
/// `start()`, `rebuild()`, and the property listeners' `rebuildAsync()` —
/// runs through `coordinator`, so two triggers for one hardware event
/// (e.g. an AirPods profile switch firing both listeners) never each
/// build their own tap/aggregate/IOProc set and leak the loser's.
public final class ProcessTapSource: SystemAudioSource, @unchecked Sendable {
    private static let log = Log(category: "process-tap-source")
    /// Sized for a few seconds of headroom at the aggregate device's
    /// typical ~512-frame/48kHz I/O buffer (~10.67ms/slot): 512 slots is
    /// roughly 5.5s, enough that a disk stall shorter than that never
    /// drops system audio even before `AudioMixer`'s own starvation
    /// padding kicks in.
    private static let ringSlotCount = 512
    /// 512 slots × 2048 frames × 4 bytes is 4MB — enough headroom above
    /// the aggregate device's typical ~512-frame I/O buffer that a chunk
    /// larger than one slot's capacity (`AudioRingBuffer.publish`'s
    /// truncation path) should be rare without preallocating 4x that for
    /// bursts this ring has never observed.
    private static let ringSlotCapacityFrames = 2048

    private struct ActiveHandles {
        let tapID: AudioObjectID
        let aggregateDeviceID: AudioObjectID
        let ioProcID: AudioDeviceIOProcID
        let listeners: PropertyListenerRegistration
    }

    private let ring = AudioRingBuffer(slotCount: ringSlotCount, slotCapacityFrames: ringSlotCapacityFrames, maxChannels: 1)
    private let coordinator = RebuildCoordinator<ActiveHandles>(label: "com.auricle.capture.process-tap.rebuild")
    /// Mutated only inside `buildHandles()`, which `coordinator` guarantees
    /// never runs concurrently with itself — safe without its own lock.
    /// Incremented on every build (including the first, via `start()`) and
    /// stamped into every chunk that build's IOProc publishes
    /// (`RawAudioChunk.sourceEpoch`), so `CaptureSession`'s effective-rate
    /// probe can tell a chunk from a fresh tap apart from one still
    /// arriving from the tap a rebuild just replaced.
    private var buildEpoch = 0

    public init() {}

    deinit {
        // An instance dropped without an explicit `stop()` must not leak
        // the tap/aggregate device until the process exits.
        if let handles = coordinator.markStoppedAndDrainInFlight() {
            Self.tearDown(handles)
        }
    }

    public var ringLossStats: RingLossStats {
        let stats = ring.snapshotDropStats()
        return RingLossStats(droppedChunkCount: stats.droppedChunkCount, truncatedChunkCount: stats.truncatedChunkCount)
    }

    public func start() throws {
        guard coordinator.isIdle else {
            throw CaptureError.streamInterrupted(reason: "ProcessTapSource.start() called more than once")
        }
        try coordinator.runSync(build: buildHandles, teardown: Self.tearDown)
    }

    public func stop() {
        if let handles = coordinator.markStoppedAndDrainInFlight() {
            Self.tearDown(handles)
        }
    }

    public func rebuild() throws {
        try coordinator.runSync(build: buildHandles, teardown: Self.tearDown)
    }

    public func drain(_ consume: (RawAudioChunk) -> Void) {
        ring.drainAll(consume)
    }

    // MARK: - Setup / teardown

    /// Builds a fresh tap, aggregate device, IOProc and property listeners
    /// and returns them — `coordinator` is what actually installs them
    /// (and tears down whatever they replace), for both the first
    /// `start()` and every later `rebuild()`.
    private func buildHandles() throws -> ActiveHandles {
        buildEpoch += 1
        let epoch = buildEpoch

        let ownProcessObjectID = try Self.processObjectID(forPID: ProcessInfo.processInfo.processIdentifier)
        let tapDescription = CATapDescription(monoGlobalTapButExcludeProcesses: [ownProcessObjectID])
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        var tapID: AudioObjectID = 0
        try Self.check(AudioHardwareCreateProcessTap(tapDescription, &tapID), "AudioHardwareCreateProcessTap")

        do {
            let sampleRate = try Self.tapSampleRate(for: tapID)
            let outputDeviceUID = try Self.defaultOutputDeviceUID()
            let aggregateDeviceID = try Self.createAggregateDevice(tapUID: tapDescription.uuid.uuidString, outputDeviceUID: outputDeviceUID)
            do {
                let ioProcID = try startIOProc(aggregateDeviceID: aggregateDeviceID, sampleRate: sampleRate, epoch: epoch)
                do {
                    let listeners = try installPropertyListeners(tapID: tapID)
                    return ActiveHandles(tapID: tapID, aggregateDeviceID: aggregateDeviceID, ioProcID: ioProcID, listeners: listeners)
                } catch {
                    AudioDeviceStop(aggregateDeviceID, ioProcID)
                    AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
                    throw error
                }
            } catch {
                AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
                throw error
            }
        } catch {
            AudioHardwareDestroyProcessTap(tapID)
            throw error
        }
    }

    /// A private aggregate device using the default output device as its
    /// main/clock sub-device (drift compensation needs a real clock to
    /// compensate against), plus the tap itself with drift compensation
    /// enabled.
    private static func createAggregateDevice(tapUID: String, outputDeviceUID: String) throws -> AudioObjectID {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "auricle-system-audio-tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceTapAutoStartKey: 1,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceClockDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputDeviceUID]],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: 1,
                ],
            ],
        ]
        var aggregateDeviceID: AudioObjectID = 0
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateDeviceID)
        try check(status, "AudioHardwareCreateAggregateDevice")
        return aggregateDeviceID
    }

    /// Registers the IOProc and starts the device, tearing the IOProc back
    /// down (but not the aggregate device — the caller owns that) if
    /// `AudioDeviceStart` fails after registration already succeeded. Runs
    /// directly on Core Audio's own I/O thread (`inDispatchQueue: nil`):
    /// `handleInput` does only a bounds check and a raw-pointer copy, work
    /// light enough to run directly on it.
    private func startIOProc(aggregateDeviceID: AudioObjectID, sampleRate: Double, epoch: Int) throws -> AudioDeviceIOProcID {
        var ioProcID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateDeviceID, nil) { [weak self] _, inInputData, inInputTime, _, _ in
            self?.handleInput(inInputData, inputTime: inInputTime, sampleRate: sampleRate, epoch: epoch)
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

    /// The two property listeners `installPropertyListeners` registers,
    /// kept together (rather than as a 3-tuple) so `ActiveHandles` and
    /// `tearDown` can pass them around as one value.
    private struct PropertyListenerRegistration {
        let queue: DispatchQueue
        let formatListener: AudioObjectPropertyListenerBlock
        let outputDeviceListener: AudioObjectPropertyListenerBlock
    }

    /// Listens for the tap's format changing and the default output
    /// device changing — either means the aggregate device this instance
    /// built is now stale (e.g. AirPods switching to HFP call mode when
    /// Teams opens the mic mid-call) — and rebuilds when either fires.
    /// Dispatched on a dedicated queue, never inline on whatever thread
    /// Core Audio's own notification machinery runs on, so tearing down
    /// the object that just notified us can't reenter that call.
    private func installPropertyListeners(tapID: AudioObjectID) throws -> PropertyListenerRegistration {
        let queue = DispatchQueue(label: "com.auricle.capture.process-tap.listeners")

        var formatAddress = Self.propertyAddress(kAudioTapPropertyFormat)
        let formatListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.rebuildAsync() }
        try Self.check(AudioObjectAddPropertyListenerBlock(tapID, &formatAddress, queue, formatListener), "AudioObjectAddPropertyListenerBlock(format)")

        var deviceAddress = Self.propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        let deviceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.rebuildAsync() }
        let deviceStatus = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &deviceAddress, queue, deviceListener)
        guard deviceStatus == noErr else {
            AudioObjectRemovePropertyListenerBlock(tapID, &formatAddress, queue, formatListener)
            throw CaptureError.streamInterrupted(reason: "AudioObjectAddPropertyListenerBlock(default output device) failed (OSStatus \(deviceStatus))")
        }
        return PropertyListenerRegistration(queue: queue, formatListener: formatListener, outputDeviceListener: deviceListener)
    }

    /// Routes the actual rebuild through `coordinator.runAsync`, never
    /// running it inline on whatever thread the property-change listener
    /// fired on (avoiding tearing down the very object that just called
    /// us) and never racing a concurrently triggered rebuild.
    private func rebuildAsync() {
        coordinator.runAsync(build: buildHandles, teardown: Self.tearDown) { error in
            Self.log.error("system audio rebuild failed", ["reason": .sensitive(String(describing: error))])
        }
    }

    /// Tears down one full tap/aggregate/IOProc/listener set. A free
    /// function rather than an instance method: `coordinator` calls it on
    /// handles this instance no longer holds a reference to once a
    /// rebuild has already installed new ones, and from `deinit`, where
    /// `self` is already being torn down.
    private static func tearDown(_ handles: ActiveHandles) {
        var formatAddress = Self.propertyAddress(kAudioTapPropertyFormat)
        AudioObjectRemovePropertyListenerBlock(handles.tapID, &formatAddress, handles.listeners.queue, handles.listeners.formatListener)
        var deviceAddress = Self.propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &deviceAddress, handles.listeners.queue, handles.listeners.outputDeviceListener)

        AudioDeviceStop(handles.aggregateDeviceID, handles.ioProcID)
        AudioDeviceDestroyIOProcID(handles.aggregateDeviceID, handles.ioProcID)
        AudioHardwareDestroyAggregateDevice(handles.aggregateDeviceID)
        AudioHardwareDestroyProcessTap(handles.tapID)
    }

    // MARK: - IOProc callback (real-time thread — see the type doc)

    private func handleInput(_ inputData: UnsafePointer<AudioBufferList>, inputTime: UnsafePointer<AudioTimeStamp>, sampleRate: Double, epoch: Int) {
        guard inputData.pointee.mNumberBuffers > 0, let data = inputData.pointee.mBuffers.mData else { return }
        let frameCount = Int(inputData.pointee.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
        guard frameCount > 0 else { return }
        // A chunk with no valid host time cannot be used for stream
        // alignment (`CaptureSession.resolveAlignmentIfPossible` compares
        // host times across the mic and system streams), so it is dropped
        // here rather than published with a placeholder value that would
        // read as a real, comparable timestamp downstream.
        let flags = inputTime.pointee.mFlags
        guard flags.contains(.hostTimeValid) else { return }
        let sampleTime = flags.contains(.sampleTimeValid) ? inputTime.pointee.mSampleTime : 0
        let channelPointer = data.assumingMemoryBound(to: Float.self)
        withUnsafePointer(to: channelPointer) { channelData in
            ring.publish(
                channelData: channelData, channelCount: 1, frameCount: frameCount, sampleRate: sampleRate,
                hostTime: inputTime.pointee.mHostTime, sampleTime: sampleTime, sourceEpoch: epoch,
            )
        }
    }

    // MARK: - Core Audio helpers

    private static func check(_ status: OSStatus, _ context: String) throws {
        guard status == noErr else {
            throw CaptureError.streamInterrupted(reason: "\(context) failed (OSStatus \(status))")
        }
    }

    /// Every property this file queries or listens on lives in the global
    /// scope's main element — the one shape `AudioObjectPropertyAddress`
    /// takes throughout, so only the selector varies at each call site.
    private static func propertyAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    /// Resolves auricle's own PID to the Process object Core Audio expects
    /// in `CATapDescription`'s exclude list — there is no simpler way to
    /// name "the current process" to this API.
    private static func processObjectID(forPID pid: pid_t) throws -> AudioObjectID {
        var address = Self.propertyAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
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

    /// The tap's declared sample rate — mono at whatever rate the system
    /// mix currently runs at, per research.md ("a tap offers mono or
    /// stereo mixdown but no sample-rate option"). `CaptureSession`'s
    /// consumer both resamples against this and cross-checks it against
    /// the rate actually observed from callback timestamps.
    private static func tapSampleRate(for tapID: AudioObjectID) throws -> Double {
        var address = Self.propertyAddress(kAudioTapPropertyFormat)
        var asbd = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &dataSize, &asbd)
        try check(status, "kAudioTapPropertyFormat")
        guard asbd.mSampleRate > 0 else {
            throw CaptureError.streamInterrupted(reason: "the tap reported a non-positive sample rate")
        }
        return asbd.mSampleRate
    }

    private static func defaultOutputDeviceUID() throws -> String {
        var address = Self.propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var deviceIDSize = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &deviceIDSize, &deviceID),
            "kAudioHardwarePropertyDefaultOutputDevice",
        )
        guard deviceID != kAudioObjectUnknown else {
            throw CaptureError.streamInterrupted(reason: "no default output device")
        }

        var uidAddress = Self.propertyAddress(kAudioDevicePropertyDeviceUID)
        var uid: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, pointer)
        }
        try check(status, "kAudioDevicePropertyDeviceUID")
        return uid as String
    }
}
