import Capture
import Core
import Permissions

/// Prompts for Microphone through `checker`. Granted advances; anything else
/// keeps the coordinator on the step so its denied copy and remediation
/// actions can render.
public struct MicrophonePermissionStep: OnboardingPermissionStep {
    public let category: TCCCategory = .microphone

    public init() {}

    public func request(using checker: PermissionChecking) async -> OnboardingPermissionOutcome {
        let status = await checker.request(.microphone)
        return status == .granted ? .advance : .remainWithStatus(status)
    }
}

/// Fires the System Audio Recording prompt by briefly running `source`
/// through `SystemAudioPermissionProbe`: macOS has no API to request or read
/// that grant, so `checker` is never consulted. For the same reason the step
/// never reports success — it always remains with `.unknown`, and its copy
/// hedges.
public struct SystemAudioPermissionStep: OnboardingPermissionStep {
    public let category: TCCCategory = .systemAudioCapture

    private let source: any SystemAudioSource
    private let log: Log

    public init(source: any SystemAudioSource, log: Log = Log(category: "onboarding-system-audio")) {
        self.source = source
        self.log = log
    }

    public func request(using _: PermissionChecking) async -> OnboardingPermissionOutcome {
        do {
            try await SystemAudioPermissionProbe.prompt(source: source)
        } catch {
            // A failed probe looks the same to the user as a declined prompt:
            // either way the remediation is System Settings, which the hedged
            // copy already points to.
            log.warn("system audio permission probe failed", [
                "error_type": .publicSafe(String(reflecting: type(of: error))),
                "error": .sensitive(String(describing: error)),
            ])
        }
        return .remainWithStatus(.unknown)
    }
}

/// Prompts for Notifications through `checker`. Granted advances; anything
/// else remains so the "notifications will be silent" copy renders before
/// the user moves on (NFR-R8) — advancing immediately would hide it.
public struct NotificationsPermissionStep: OnboardingPermissionStep {
    public let category: TCCCategory = .notifications

    public init() {}

    public func request(using checker: PermissionChecking) async -> OnboardingPermissionOutcome {
        let status = await checker.request(.notifications)
        return status == .granted ? .advance : .remainWithStatus(status)
    }
}
