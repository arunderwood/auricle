import Foundation
import Observation
import Permissions

/// Drives the J0 onboarding narrative (UX-DR41): Welcome → Microphone →
/// System Audio → Notifications → Configure → Done. Permission steps are
/// injected as `OnboardingPermissionStep`s, so a richer conforming step can
/// replace the placeholder without this type changing; `PermissionChecking`
/// is injected too — `AuricleApp` passes the one shared `PermissionChecker`
/// instance the rest of the app uses (AR-PAT-4) rather than this type
/// constructing its own. `opener` is required, with no default, so a test
/// can never reach System Settings through it.
@MainActor @Observable
public final class OnboardingCoordinator {
    public private(set) var step: OnboardingStep = .welcome
    /// The last `.remainWithStatus` the current permission step returned;
    /// nil until its request has run, and reset on every step change.
    public private(set) var permissionStatus: PermissionStatus?
    public let configure: OnboardingConfigureModel

    private let checker: any PermissionChecking
    private let opener: URLOpener
    private let permissionSteps: [TCCCategory: any OnboardingPermissionStep]
    private let applicationSupportDirectory: URL
    private let progress: OnboardingProgress
    private var completed = false

    public init(
        checker: any PermissionChecking,
        configure: OnboardingConfigureModel,
        applicationSupportDirectory: URL,
        progress: OnboardingProgress,
        opener: @escaping URLOpener,
        permissionSteps: [TCCCategory: any OnboardingPermissionStep]? = nil,
    ) {
        self.checker = checker
        self.opener = opener
        self.configure = configure
        self.permissionSteps = permissionSteps ?? [
            .microphone: DefaultPermissionStep(category: .microphone),
            .systemAudioCapture: DefaultPermissionStep(category: .systemAudioCapture),
            .notifications: DefaultPermissionStep(category: .notifications),
        ]
        self.applicationSupportDirectory = applicationSupportDirectory
        self.progress = progress
    }

    /// Moves to the next step in `OnboardingStep.allCases` order. A no-op
    /// once `step` is already `.done`.
    public func advance() {
        let steps = OnboardingStep.allCases
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else { return }
        step = steps[index + 1]
        permissionStatus = nil
    }

    /// The TCC category the current step asks for; nil off a permission step.
    public var currentPermissionCategory: TCCCategory? {
        permissionCategory(for: step)
    }

    /// What the current permission step's screen shows; nil off a permission step.
    public var permissionContent: PermissionStepContent? {
        currentPermissionCategory.flatMap { PermissionStepContent.make(category: $0, status: permissionStatus) }
    }

    /// The Skip/Continue path: moves on without another request. A no-op
    /// off a permission step, so a stale tap can't skip Configure.
    public func continuePastCurrentPermission() {
        guard currentPermissionCategory != nil else { return }
        advance()
    }

    /// Opens the current category's System Settings pane. Does nothing when
    /// the checker has no deep link for it.
    public func openCurrentPermissionSettings() async {
        guard let category = currentPermissionCategory, let url = checker.remediationDeepLink(for: category) else { return }
        _ = await opener(url)
    }

    public func perform(_ action: PermissionStepAction) async {
        switch action {
        case .request, .tryAgain:
            await requestCurrentPermission()
        case .openSettings:
            await openCurrentPermissionSettings()
        case .skip, .continueOnward:
            continuePastCurrentPermission()
        }
    }

    /// Runs the current step's permission request — a no-op when `step`
    /// isn't a permission step — and advances per its
    /// `OnboardingPermissionOutcome`.
    public func requestCurrentPermission() async {
        guard let category = permissionCategory(for: step), let permissionStep = permissionSteps[category] else { return }
        let requestedStep = step
        let outcome = await permissionStep.request(using: checker)
        // The step may have moved on while the request was suspended; its
        // outcome belongs to the step that asked, not the one now showing.
        guard step == requestedStep else { return }
        switch outcome {
        case .advance:
            advance()
        case let .remainWithStatus(status):
            permissionStatus = status
        }
    }

    /// Writes the validated vault path to config and the first-run marker.
    /// Called once, from `DoneStepView`'s `onAppear`.
    public func completeOnboarding() throws {
        try configure.finish()
        try OnboardingMarker.write(applicationSupportDirectory: applicationSupportDirectory)
        completed = true
    }

    /// Hands the window over to the main app. A no-op until
    /// `completeOnboarding()` has succeeded: without the marker on disk, the
    /// next launch would put the user back through onboarding.
    public func enterApp() {
        guard completed else { return }
        progress.markComplete()
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
