import AppUI
import Capture
import Core
import Foundation
import Notifications
import Permissions
import State
import Telemetry
import Testing

#if DEBUG

    // MARK: - Test doubles

    /// A `CaptureRecording` with no audio hardware: `start()` reports whatever
    /// `micIncluded`/`startError` the test configured, `stop()` finalizes
    /// nothing and hands back a URL `CaptureStage` never has to read.
    private final class FakeCaptureRecording: CaptureRecording, @unchecked Sendable {
        let faults: AsyncStream<CaptureStreamFault>
        private let continuation: AsyncStream<CaptureStreamFault>.Continuation
        /// Mutable so one test can flip a denied session to granted between
        /// successive `start()` calls, the way a real mic grant changes mid-test.
        var micIncluded: Bool
        private let startError: Error?

        init(micIncluded: Bool = true, startError: Error? = nil) {
            (faults, continuation) = AsyncStream<CaptureStreamFault>.makeStream()
            self.micIncluded = micIncluded
            self.startError = startError
        }

        var watchdogStats: CaptureWatchdogStats {
            CaptureWatchdogStats()
        }

        func start() async throws -> CaptureSessionStartResult {
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
    }

    /// Reports a fixed deep link for `.microphone` only, matching
    /// `PermissionChecker.remediationDeepLink(for:)`'s own `nil`-for-unsupported
    /// shape without depending on the real TCC-backed checker.
    private struct FakePermissionChecker: PermissionChecking {
        let microphoneDeepLink: URL?

        func check(_: TCCCategory) async -> PermissionStatus {
            .unknown
        }

        func request(_: TCCCategory) async -> PermissionStatus {
            .unknown
        }

        func refresh() async {}
        func remediationDeepLink(for category: TCCCategory) -> URL? {
            category == .microphone ? microphoneDeepLink : nil
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
    private func makeStage(session: FakeCaptureRecording) throws -> CaptureStage {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try StateStore.production(path: root.appendingPathComponent("state.sqlite3").path)
        return CaptureStage(
            stateStore: store,
            stageEventLogger: StageEventLogger(stateStore: store),
            notifier: StdoutNotifier(vaultRoot: root, sink: { _ in }),
            makeSession: { _ in session },
            cacheDirectory: { root.appendingPathComponent($0.rawValue, isDirectory: true) },
        )
    }

    @MainActor
    private func makeTrigger(
        stage: CaptureStage,
        microphoneDeepLink: URL? = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone"),
        opened: OpenedURLs = OpenedURLs(),
    ) -> DebugCaptureTrigger {
        DebugCaptureTrigger(
            stage: stage,
            checker: FakePermissionChecker(microphoneDeepLink: microphoneDeepLink),
            opener: { url in
                opened.record(url)
                return true
            },
        )
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
    }

#endif
