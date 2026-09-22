/// The J0 onboarding narrative's steps (UX-DR41), in the order
/// `OnboardingCoordinator` advances through them. `.configure` covers every
/// `ConfigureSubStep` as one step — `OnboardingConfigureModel` sequences
/// those, not exposed as separate cases here.
public enum OnboardingStep: CaseIterable, Sendable, Equatable {
    case welcome
    case microphone
    case systemAudio
    case notifications
    case configure
    case done
}
