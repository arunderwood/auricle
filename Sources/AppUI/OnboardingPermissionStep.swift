import Permissions

/// What a permission step decided after `request(using:)` ran. Story 5.8's
/// richer steps use `.remainWithStatus` to keep the coordinator on a
/// denied/not-determined step so its view can show remediation copy; this
/// story's `DefaultPermissionStep` never returns it.
public enum OnboardingPermissionOutcome: Sendable, Equatable {
    case advance
    case remainWithStatus(PermissionStatus)
}

/// The seam Story 5.8 plugs its per-permission-step copy and buttons into:
/// it only decides whether `OnboardingCoordinator` advances past a
/// permission step. It never renders anything — views stay in `App/`.
public protocol OnboardingPermissionStep: Sendable {
    var category: TCCCategory { get }
    func request(using checker: PermissionChecking) async -> OnboardingPermissionOutcome
}

/// This story's placeholder for all three permission steps: prompts once
/// through `checker` and always advances, regardless of the resulting
/// status. Story 5.8 supplies the conforming steps that inspect the status
/// and remain on a denied/not-determined step instead.
public struct DefaultPermissionStep: OnboardingPermissionStep {
    public let category: TCCCategory

    public init(category: TCCCategory) {
        self.category = category
    }

    public func request(using checker: PermissionChecking) async -> OnboardingPermissionOutcome {
        _ = await checker.request(category)
        return .advance
    }
}
