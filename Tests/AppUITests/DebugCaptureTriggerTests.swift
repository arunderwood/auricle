import AppUI
import Capture
import Core
import Foundation
import Notifications
import Permissions
import State
import Telemetry
import Testing
import TestSupport

#if DEBUG

    // MARK: - Test doubles

    /// A `CaptureRecording` with no audio hardware: `start()` reports whatever
    /// `micIncluded`/`startError` the test configured, `stop()` finalizes
    /// nothing and hands back a URL `CaptureStage` never has to read, and
    /// `emit` stands in for an input reporting a fault. `onStart` runs at the
    /// top of `start()`, so a test can act while the start is in flight.
    private final class FakeCaptureRecording: CaptureRecording, @unchecked Sendable {
        let faults: AsyncStream<CaptureStreamFault>
        private let continuation: AsyncStream<CaptureStreamFault>.Continuation
        /// Mutable so one test can flip a denied session to granted between
        /// successive `start()` calls, the way a real mic grant changes mid-test.
        var micIncluded: Bool
        private let startError: Error?
        private let onStart: (@Sendable () async -> Void)?

        init(micIncluded: Bool = true, startError: Error? = nil, onStart: (@Sendable () async -> Void)? = nil) {
            (faults, continuation) = AsyncStream<CaptureStreamFault>.makeStream()
            self.micIncluded = micIncluded
            self.startError = startError
            self.onStart = onStart
        }

        var watchdogStats: CaptureWatchdogStats {
            CaptureWatchdogStats()
        }

        func start() async throws -> CaptureSessionStartResult {
            await onStart?()
            if let startError {
                throw startError
            }
            return CaptureSessionStartResult(micIncluded: micIncluded)
        }

        func stop() async throws -> URL {
            continuation.finish()
            return FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        }

        func restart(_: CaptureSource) async throws {}

        func emit(_ fault: CaptureStreamFault) {
            continuation.yield(fault)
        }
    }

    /// Records every URL handed to a `URLOpener`, guarded for concurrent access
    /// the way `Recorder` does in `OnboardingCoordinatorTests`.
    private final class OpenedURLs: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []

        func record(_ url: URL) {
            lock.withLock { urls.append(url) }
        }

        var all: [URL] {
            lock.withLock { urls }
        }
    }

    /// A fresh `CaptureStage` over a real, temp-file-backed `StateStore` — public
    /// API only, no `@testable`, mirroring `Tests/CaptureTests/CaptureStageFixture.swift`
    /// without reaching into `Capture`'s internals.
    private func makeStage(session: FakeCaptureRecording, store givenStore: StateStore? = nil) throws -> CaptureStage {
        try makeStage(store: givenStore) { _ in session }
    }

    private func makeStage(store givenStore: StateStore? = nil, makeSession: @escaping CaptureStage.SessionFactory) throws -> CaptureStage {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try givenStore ?? StateStore.production(path: root.appendingPathComponent("state.sqlite3").path)
        return CaptureStage(
            stateStore: store,
            stageEventLogger: StageEventLogger(stateStore: store),
            notifier: StdoutNotifier(vaultRoot: root, sink: { _ in }),
            makeSession: makeSession,
            cacheDirectory: { root.appendingPathComponent($0.rawValue, isDirectory: true) },
        )
    }

    private func makeStore() throws -> StateStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try StateStore.production(path: root.appendingPathComponent("state.sqlite3").path)
    }

    /// The meeting `store` holds in `recording`: the one the trigger started.
    private func recordingMeetingID(in store: StateStore) async throws -> MeetingID? {
        try await store.fetchPending()
            .first { $0.state == PipelineState.recording.rawValue }
            .flatMap { MeetingID(ulid: $0.id) }
    }

    /// `endedCaptures` defaults to the stage's own stream; a test that needs
    /// to report an end the stage never produced passes its own.
    @MainActor
    private func makeTrigger(
        stage: CaptureStage,
        endedCaptures: AsyncStream<MeetingID>? = nil,
        progress: OnboardingProgress = OnboardingProgress(isComplete: true),
        microphoneDeepLink: URL? = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone"),
        opened: OpenedURLs = OpenedURLs(),
    ) -> DebugCaptureTrigger {
        DebugCaptureTrigger(
            stage: stage,
            endedCaptures: endedCaptures ?? stage.endedCaptures,
            progress: progress,
            checker: FakePermissionChecker(
                checkResult: .unknown,
                requestResult: .unknown,
                deepLinks: microphoneDeepLink.map { [.microphone: $0] } ?? [:],
            ),
            opener: { url in
                opened.record(url)
                return true
            },
        )
    }

    /// A value a `@Sendable` closure can set and a test can read.
    private final class Locked<Value: Sendable>: @unchecked Sendable {
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

    /// Polls on the main actor, so the trigger's own listener gets turns in
    /// between. The timeout only bounds a failing test.
    @MainActor
    private func eventually(timeout: TimeInterval = 30, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                Issue.record("condition not met within \(timeout)s")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Tests

    @MainActor
    struct DebugCaptureTriggerTests {
        @Test func toggleWhileIdleWithMicGrantedStartsRecordingWithNoAlert() async throws {
            let stage = try makeStage(session: FakeCaptureRecording(micIncluded: true))
            let trigger = makeTrigger(stage: stage)

            await trigger.toggle()

            #expect(trigger.isRecording)
            #expect(trigger.microphoneDeniedAlert == nil)
        }

        @Test func toggleWhileIdleWithMicDeniedStartsRecordingAndSetsAlert() async throws {
            let stage = try makeStage(session: FakeCaptureRecording(micIncluded: false))
            let deepLink = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone")
            let trigger = makeTrigger(stage: stage, microphoneDeepLink: deepLink)

            await trigger.toggle()

            #expect(trigger.isRecording)
            #expect(trigger.microphoneDeniedAlert?.message == PermissionStepContent.microphoneSkipCaption)
            #expect(trigger.microphoneDeniedAlert?.settingsURL == deepLink)
        }

        @Test func toggleWhileRunningStopsCaptureAndClearsTrackedMeeting() async throws {
            let stage = try makeStage(session: FakeCaptureRecording(micIncluded: true))
            let trigger = makeTrigger(stage: stage)

            await trigger.toggle()
            #expect(trigger.isRecording)
            await trigger.toggle()
            #expect(!trigger.isRecording)

            // `CaptureStage` allows only one live meeting at a time: if the
            // trigger's stop had not actually reached it, this start would
            // throw `captureAlreadyLive` instead of succeeding.
            let result = try await stage.start()
            #expect(!result.meetingID.rawValue.isEmpty)
        }

        @Test func toggleWhileIdleWhenStartThrowsLeavesRecordingFalseAndTracksNothing() async throws {
            let stage = try makeStage(session: FakeCaptureRecording(micIncluded: true))
            // A capture already live at the `CaptureStage` level, started
            // outside the trigger, so its own `liveMeetingID` stays nil.
            let alreadyLive = try await stage.start().meetingID
            let trigger = makeTrigger(stage: stage)

            await trigger.toggle()

            #expect(!trigger.isRecording)
            #expect(trigger.microphoneDeniedAlert == nil)

            // No id was mistakenly tracked: the next toggle still attempts a
            // *start*, which only succeeds once the real live capture is gone.
            _ = try? await stage.stop(meetingID: alreadyLive)
            await trigger.toggle()
            #expect(trigger.isRecording)
        }

        @Test func openMicrophoneSettingsOpensTheAlertsDeepLink() async throws {
            let stage = try makeStage(session: FakeCaptureRecording(micIncluded: false))
            let deepLink = try #require(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone"))
            let opened = OpenedURLs()
            let trigger = makeTrigger(stage: stage, microphoneDeepLink: deepLink, opened: opened)

            await trigger.toggle()
            await trigger.openMicrophoneSettings()

            #expect(opened.all == [deepLink])
        }

        @Test func dismissMicrophoneDeniedAlertClearsIt() async throws {
            let stage = try makeStage(session: FakeCaptureRecording(micIncluded: false))
            let trigger = makeTrigger(stage: stage)

            await trigger.toggle()
            #expect(trigger.microphoneDeniedAlert != nil)
            trigger.dismissMicrophoneDeniedAlert()
            #expect(trigger.microphoneDeniedAlert == nil)
        }

        @Test func toggleWithMicGrantedClearsAStaleMicrophoneDeniedAlert() async throws {
            let session = FakeCaptureRecording(micIncluded: false)
            let stage = try makeStage(session: session)
            let trigger = makeTrigger(stage: stage)

            await trigger.toggle()
            #expect(trigger.microphoneDeniedAlert != nil)
            await trigger.toggle()
            #expect(!trigger.isRecording)

            // Same trigger, same underlying session — only the mic grant
            // changed. The earlier denial's alert must not persist into this
            // session, which actually included the mic.
            session.micIncluded = true
            await trigger.toggle()
            #expect(trigger.microphoneDeniedAlert == nil)
        }

        @Test func aCaptureTheStageEndsItselfReturnsTheTriggerToIdle() async throws {
            let session = FakeCaptureRecording(micIncluded: true)
            let stage = try makeStage(session: session)
            let trigger = makeTrigger(stage: stage)
            await trigger.toggle()
            #expect(trigger.isRecording)

            session.emit(.permissionRevoked(.microphone))

            try await eventually { !trigger.isRecording }
            // Idle means the next press starts a new capture, which only
            // succeeds because the stage has no live capture left.
            await trigger.toggle()
            #expect(trigger.isRecording)
        }

        @Test func anEndForAnotherMeetingLeavesTheTriggerRecording() async throws {
            let store = try makeStore()
            let stage = try makeStage(session: FakeCaptureRecording(micIncluded: true), store: store)
            let (ended, reportEnd) = AsyncStream<MeetingID>.makeStream()
            let trigger = makeTrigger(stage: stage, endedCaptures: ended)
            await trigger.toggle()
            #expect(trigger.isRecording)

            reportEnd.yield(MeetingID.generate())
            // Suspending hands the main actor to the listener, which takes
            // the stale end off the stream.
            try await Task.sleep(for: .milliseconds(100))

            #expect(trigger.isRecording)
            // The same listener does act on an end for the tracked meeting.
            let liveID = try #require(await recordingMeetingID(in: store))
            reportEnd.yield(liveID)
            try await eventually { !trigger.isRecording }
        }

        @Test func aCaptureThatEndsBeforeStartReturnsLeavesTheTriggerIdle() async throws {
            let (ended, reportEnd) = AsyncStream<MeetingID>.makeStream()
            let stage = try makeStage { meetingID in
                FakeCaptureRecording(onStart: {
                    reportEnd.yield(meetingID)
                    // Suspending hands the main actor to the listener, which
                    // hears the end before `start()` returns.
                    try? await Task.sleep(for: .milliseconds(100))
                })
            }
            let trigger = makeTrigger(stage: stage, endedCaptures: ended)

            await trigger.toggle()

            #expect(!trigger.isRecording)
        }

        @Test func aSecondPressWhileAStartIsInFlightIsANoOp() async throws {
            let startedID = Locked<MeetingID?>(nil)
            let (gate, openGate) = AsyncStream<Void>.makeStream()
            let (ended, reportEnd) = AsyncStream<MeetingID>.makeStream()
            let stage = try makeStage { meetingID in
                FakeCaptureRecording(onStart: {
                    startedID.value = meetingID
                    for await _ in gate {
                        break
                    }
                })
            }
            let trigger = makeTrigger(stage: stage, endedCaptures: ended)
            let firstPress = Task { await trigger.toggle() }
            try await eventually { startedID.value != nil }

            await trigger.toggle()
            // The first capture ends while its start is still suspended; the
            // second press must not have discarded the record of that end.
            try reportEnd.yield(#require(startedID.value))
            try await Task.sleep(for: .milliseconds(100))
            openGate.yield()
            await firstPress.value

            #expect(!trigger.isRecording)
        }

        @Test func toggleBeforeOnboardingCompletesDoesNothing() async throws {
            let stage = try makeStage(session: FakeCaptureRecording(micIncluded: true))
            let progress = OnboardingProgress(isComplete: false)
            let trigger = makeTrigger(stage: stage, progress: progress)

            #expect(!trigger.isAvailable)
            await trigger.toggle()

            #expect(!trigger.isRecording)
            // No capture was started behind the trigger's back: the stage
            // still accepts one.
            let result = try await stage.start()
            _ = try await stage.stop(meetingID: result.meetingID)

            progress.markComplete()
            #expect(trigger.isAvailable)
            await trigger.toggle()
            #expect(trigger.isRecording)
        }
    }

#endif
