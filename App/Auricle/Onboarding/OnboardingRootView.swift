import AppUI
import SwiftUI

/// Hosts `OnboardingCoordinator` and switches on its `step` to the matching
/// per-step view. `AuricleApp` swaps this in for the app's normal root view
/// when no completion marker exists yet, in the existing window.
struct OnboardingRootView: View {
    @State private var coordinator: OnboardingCoordinator

    init(coordinator: OnboardingCoordinator) {
        _coordinator = State(initialValue: coordinator)
    }

    var body: some View {
        Group {
            switch coordinator.step {
            case .welcome:
                WelcomeStepView(coordinator: coordinator)
            case .microphone, .systemAudio, .notifications:
                PermissionStepView(coordinator: coordinator)
            case .configure:
                ConfigureStepView(coordinator: coordinator)
            case .done:
                DoneStepView(coordinator: coordinator)
            }
        }
        .frame(minWidth: 480, minHeight: 360)
    }
}
