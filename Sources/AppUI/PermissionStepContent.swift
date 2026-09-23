import Permissions

/// A button a permission step's screen can show. `OnboardingCoordinator.perform(_:)`
/// is the one place each maps to behavior.
public enum PermissionStepAction: Sendable, Hashable {
    /// Runs the step's first request.
    case request
    case openSettings
    /// Moves on without the grant (Microphone only).
    case skip
    /// Re-runs the request; offered only while macOS can still prompt.
    case tryAgain
    case continueOnward
}

/// Everything a permission step's screen renders, as a pure function of
/// (category, last request status). The view only lays this out and forwards
/// taps, so which copy and which buttons appear is covered by `swift test`.
public struct PermissionStepContent: Sendable, Equatable {
    public let title: String
    /// Shown before the OS dialog so the prompt is never a surprise.
    public let whyLine: String
    public let requestButtonTitle: String
    /// Shown at every status, before and after the request.
    public let standingNote: String?
    /// The result of the last request; nil until one has run.
    public let followUp: String?
    public let skipCaption: String?
    public let actions: [PermissionStepAction]

    /// `status` is nil until the step's request has run at least once.
    /// `.calendarOAuth` is not an onboarding permission step and yields nil.
    public static func make(category: TCCCategory, status: PermissionStatus?) -> PermissionStepContent? {
        switch category {
        case .microphone: microphone(status: status)
        case .systemAudioCapture: systemAudio(status: status)
        case .notifications: notifications(status: status)
        case .calendarOAuth: nil
        }
    }

    public static let microphoneDeniedMessage =
        "auricle needs microphone access to capture your voice. You can grant it in System Settings."
    public static let systemAudioHedgeMessage =
        "If you chose Allow, you're done. If not, you can turn on System Audio Recording for auricle in System Settings."
    public static let systemAudioStandingNote = "Without it, recordings contain only your microphone."
    public static let notificationsDeniedMessage =
        "You can still use auricle — summary-ready notifications will be silent. You'll see ready meetings in the main window."
    public static let microphoneSkipCaption = "Recordings will have system audio only."

    private static func microphone(status: PermissionStatus?) -> PermissionStepContent {
        let followUp: String?
        let actions: [PermissionStepAction]
        switch status {
        case nil:
            followUp = nil
            actions = [.request]
        case .granted:
            followUp = nil
            actions = [.continueOnward]
        case .notDetermined:
            followUp = microphoneDeniedMessage
            actions = [.openSettings, .skip, .tryAgain]
        case .denied, .unknown:
            followUp = microphoneDeniedMessage
            actions = [.openSettings, .skip]
        }
        return PermissionStepContent(
            title: "Microphone",
            whyLine: "auricle records your side of the meeting through the microphone, so your own words make it into the notes.",
            requestButtonTitle: "Grant Microphone access",
            standingNote: nil,
            followUp: followUp,
            skipCaption: actions.contains(.skip) ? microphoneSkipCaption : nil,
            actions: actions,
        )
    }

    /// Every post-request status gets the same hedge: the grant cannot be
    /// read back, so no status is evidence the user chose Allow.
    private static func systemAudio(status: PermissionStatus?) -> PermissionStepContent {
        PermissionStepContent(
            title: "System Audio",
            whyLine: "auricle records what everyone else in the meeting says by capturing your Mac's audio output. macOS asks once.",
            requestButtonTitle: "Allow System Audio Recording",
            standingNote: systemAudioStandingNote,
            followUp: status == nil ? nil : systemAudioHedgeMessage,
            skipCaption: nil,
            actions: status == nil ? [.request] : [.openSettings, .continueOnward],
        )
    }

    private static func notifications(status: PermissionStatus?) -> PermissionStepContent {
        let followUp: String? = switch status {
        case nil, .granted: nil
        case .denied, .notDetermined, .unknown: notificationsDeniedMessage
        }
        return PermissionStepContent(
            title: "Notifications",
            whyLine: "auricle tells you when a meeting's summary is ready.",
            requestButtonTitle: "Allow notifications",
            standingNote: nil,
            followUp: followUp,
            skipCaption: nil,
            actions: status == nil ? [.request] : [.continueOnward],
        )
    }
}
