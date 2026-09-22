import Foundation
import Observation
import Permissions

/// Drives the J0 onboarding narrative (UX-DR41): Welcome → Microphone →
/// System Audio → Notifications → Configure → Done. Permission steps are
/// injected as `OnboardingPermissionStep`s, so a richer conforming step can
/// replace the placeholder without this type changing; `PermissionChecking`
/// is injected too — `AuricleApp` passes the one shared `PermissionChecker`
/// instance the rest of the app uses (AR-PAT-4) rather than this type
/// constructing its own.
@MainActor @Observable
public final class OnboardingCoordinator {
    public private(set) var step: OnboardingStep = .welcome
    public let configure: OnboardingConfigureModel

    private let checker: any PermissionChecking
    private let permissionSteps: [TCCCategory: any OnboardingPermissionStep]
    private let applicationSupportDirectory: URL

    public init(
        checker: any PermissionChecking,
        configure: OnboardingConfigureModel,
        applicationSupportDirectory: URL,
        permissionSteps: [TCCCategory: any OnboardingPermissionStep]? = nil,
    ) {
        self.checker = checker
        self.configure = configure
        self.permissionSteps = permissionSteps ?? [
            .microphone: DefaultPermissionStep(category: .microphone),
            .systemAudioCapture: DefaultPermissionStep(category: .systemAudioCapture),
            .notifications: DefaultPermissionStep(category: .notifications),
        ]
        self.applicationSupportDirectory = applicationSupportDirectory
    }

    /// Moves to the next step in `OnboardingStep.allCases` order. A no-op
    /// once `step` is already `.done`.
    public func advance() {
        let steps = OnboardingStep.allCases
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else { return }
        step = steps[index + 1]
    }

    /// Runs the current step's permission request — a no-op when `step`
    /// isn't a permission step — and advances per its
    /// `OnboardingPermissionOutcome`.
    public func requestCurrentPermission() async {
        guard let category = permissionCategory(for: step), let permissionStep = permissionSteps[category] else { return }
        switch await permissionStep.request(using: checker) {
        case .advance:
            advance()
        case .remainWithStatus:
            break
        }
    }

    /// Writes the validated vault path to config and the first-run marker.
    /// Called once, from `DoneStepView`'s `onAppear`.
    public func completeOnboarding() throws {
        try configure.finish()
        try OnboardingMarker.write(applicationSupportDirectory: applicationSupportDirectory)
    }

    private func permissionCategory(for step: OnboardingStep) -> TCCCategory? {
        switch step {
        case .microphone: .microphone
        case .systemAudio: .systemAudioCapture
        case .notifications: .notifications
        case .welcome, .configure, .done: nil
        }
    }
}
