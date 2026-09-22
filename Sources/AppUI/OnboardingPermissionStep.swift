import Permissions

/// What a permission step decided after `request(using:)` ran. A richer step
/// uses `.remainWithStatus` to keep the coordinator on a denied/not-determined
/// step so its view can show remediation copy; `DefaultPermissionStep` never
/// returns it.
public enum OnboardingPermissionOutcome: Sendable, Equatable {
    case advance
    case remainWithStatus(PermissionStatus)
}

/// The seam a permission step's own copy and buttons plug into: it only
/// decides whether `OnboardingCoordinator` advances past a permission step.
/// It never renders anything — views stay in `App/`.
public protocol OnboardingPermissionStep: Sendable {
    var category: TCCCategory { get }
    func request(using checker: PermissionChecking) async -> OnboardingPermissionOutcome
}

/// No-op step used until a real permission step is registered for this
/// category: prompts once through `checker` and always advances, regardless
/// of the resulting status.
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
