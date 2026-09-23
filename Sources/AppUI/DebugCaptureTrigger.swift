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
    @MainActor @Observable
    public final class DebugCaptureTrigger {
        public private(set) var isRecording = false
        public private(set) var microphoneDeniedAlert: MicrophoneDeniedAlert?

        private var liveMeetingID: MeetingID?
        private let stage: CaptureStage
        private let checker: any PermissionChecking
        private let opener: URLOpener

        public init(stage: CaptureStage, checker: any PermissionChecking, opener: @escaping URLOpener) {
            self.stage = stage
            self.checker = checker
            self.opener = opener
        }

        /// Starts a capture while idle, or stops the live one. `start()`/`stop()`
        /// failures are swallowed here rather than surfaced — some `CaptureStage`
        /// failure paths log and others don't, so this trigger doesn't rely on
        /// any of them being logged, and a debug trigger has no user-facing
        /// error path of its own.
        public func toggle() async {
            if let meetingID = liveMeetingID {
                _ = try? await stage.stop(meetingID: meetingID)
                liveMeetingID = nil
                isRecording = false
            } else {
                guard let result = try? await stage.start() else { return }
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
