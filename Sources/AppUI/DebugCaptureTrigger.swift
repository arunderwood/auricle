import Capture
import Core
import Foundation
import Observation
import Permissions

#if DEBUG

    /// A mic-denied result from `toggle()`: the Story 5.1 skip caption, plus the
    /// Settings deep link when the checker has one.
    public struct MicrophoneDeniedAlert: Sendable, Equatable {
        public let message: String
        public let settingsURL: URL?

        public init(message: String, settingsURL: URL?) {
            self.message = message
            self.settingsURL = settingsURL
        }
    }

    /// Toggles a `CaptureStage` recording from the Debug-only `Cmd-Shift-R` menu
    /// command (Story 5.6), so the process-tap backend can be exercised before
    /// Epic 6's real Record button exists. `CaptureStage` has no public "is a
    /// capture live" query, so this type tracks the `MeetingID` `start()` hands
    /// back itself, and passes it to `stop(meetingID:)`.
    ///
    /// The stage can also end a capture on its own, on a revoked microphone or
    /// an input that keeps failing. `endedCaptures` reports those, and an end
    /// for the tracked meeting returns this trigger to idle. An end for any
    /// other meeting is stale and ignored.
    ///
    /// Unavailable until onboarding is complete: a capture started from the
    /// onboarding window would have no indicator and no mic-denied alert.
    @MainActor @Observable
    public final class DebugCaptureTrigger {
        public private(set) var isRecording = false
        public private(set) var microphoneDeniedAlert: MicrophoneDeniedAlert?

        private var liveMeetingID: MeetingID?
        /// Ends heard while a `start()` is in flight, whose id this type does
        /// not know yet. A capture that fails before `start()` returns must
        /// not be tracked as live afterwards.
        private var endedDuringStart: Set<MeetingID>?
        private let stage: CaptureStage
        private let progress: OnboardingProgress
        private let checker: any PermissionChecking
        private let opener: URLOpener
        private static let log = Log(category: "debug-capture-trigger")

        /// `endedCaptures` is normally `stage.endedCaptures`, the stream's one
        /// consumer. It is its own parameter so a test can report an end the
        /// stage never produced.
        public init(
            stage: CaptureStage,
            endedCaptures: AsyncStream<MeetingID>,
            progress: OnboardingProgress,
            checker: any PermissionChecking,
            opener: @escaping URLOpener,
        ) {
            self.stage = stage
            self.progress = progress
            self.checker = checker
            self.opener = opener
            Task { [weak self] in
                for await meetingID in endedCaptures {
                    guard let self else { return }
                    captureEnded(meetingID)
                }
            }
        }

        public var isAvailable: Bool {
            progress.isComplete
        }

        /// Starts a capture while idle, or stops the live one. Does nothing
        /// while unavailable. A debug trigger has no user-facing error path,
        /// so a failed start or stop is logged and the trigger stays idle.
        public func toggle() async {
            guard isAvailable else { return }
            if let meetingID = liveMeetingID {
                do {
                    _ = try await stage.stop(meetingID: meetingID)
                } catch {
                    Self.log.warn("debug capture stop failed", Self.fields(meetingID: meetingID, error: error))
                }
                clear()
            } else {
                await start()
            }
        }

        /// A press while a start is in flight does nothing: a second start
        /// would only be refused as `captureAlreadyLive`, and its cleanup
        /// would drop the first start's record of ends.
        private func start() async {
            guard endedDuringStart == nil else { return }
            endedDuringStart = []
            defer { endedDuringStart = nil }
            let result: CaptureStartResult
            do {
                result = try await stage.start()
            } catch {
                Self.log.warn("debug capture start failed", Self.fields(meetingID: nil, error: error))
                return
            }
            guard endedDuringStart?.contains(result.meetingID) != true else { return }
            liveMeetingID = result.meetingID
            isRecording = true
            if !result.micIncluded {
                microphoneDeniedAlert = MicrophoneDeniedAlert(
                    message: PermissionStepContent.microphoneSkipCaption,
                    settingsURL: checker.remediationDeepLink(for: .microphone),
                )
            } else {
                microphoneDeniedAlert = nil
            }
        }

        private func captureEnded(_ meetingID: MeetingID) {
            endedDuringStart?.insert(meetingID)
            guard meetingID == liveMeetingID else { return }
            clear()
        }

        private func clear() {
            liveMeetingID = nil
            isRecording = false
        }

        private static func fields(meetingID: MeetingID?, error: Error) -> [String: LogSensitivity] {
            var fields: [String: LogSensitivity] = [
                "error_type": .publicSafe(String(describing: type(of: error))),
                "reason": .sensitive(String(describing: error)),
            ]
            if let meetingID {
                fields["meeting_id"] = .publicSafe(meetingID.rawValue)
            }
            return fields
        }

        /// Opens the mic-denied alert's Settings deep link, when it has one.
        public func openMicrophoneSettings() async {
            guard let url = microphoneDeniedAlert?.settingsURL else { return }
            _ = await opener(url)
        }

        public func dismissMicrophoneDeniedAlert() {
            microphoneDeniedAlert = nil
        }
    }

#endif
