/// The J0 onboarding narrative's steps (UX-DR41), in the order
/// `OnboardingCoordinator` advances through them. `.configure` covers all
/// four Configure sub-steps (vault path, Obsidian check, API key,
/// expectations) as one step — they are sequenced within
/// `ConfigureStepView`, not exposed as separate cases here.
public enum OnboardingStep: CaseIterable, Sendable, Equatable {
    case welcome
    case microphone
    case systemAudio
    case notifications
    case configure
    case done
}
