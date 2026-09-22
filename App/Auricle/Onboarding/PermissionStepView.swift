import AppUI
import SwiftUI

/// This story's single placeholder screen for all three permission steps
/// (Microphone, System Audio, Notifications): one button that runs the
/// current step's request and advances regardless of outcome. Story 5.8
/// replaces this with per-step copy, denied-state handling, and Open
/// Settings/Skip/Try Again buttons, driven by the same
/// `OnboardingPermissionStep` seam this story defines.
struct PermissionStepView: View {
    let coordinator: OnboardingCoordinator

    /// Guards against a second tap starting a second `requestCurrentPermission()`
    /// while the first is still in flight, which could advance past a whole
    /// permission step the user never actually saw a result for.
    @State private var isRequesting = false

    var body: some View {
        VStack(spacing: 20) {
            Text(title)
                .font(.title2)
            Button("Continue") {
                guard !isRequesting else { return }
                isRequesting = true
                Task {
                    await coordinator.requestCurrentPermission()
                    isRequesting = false
                }
            }
            .accessibilityLabel("Continue")
            .buttonStyle(.borderedProminent)
            .disabled(isRequesting)
        }
        .padding(32)
    }

    private var title: String {
        switch coordinator.step {
        case .microphone: "Microphone"
        case .systemAudio: "System Audio"
        case .notifications: "Notifications"
        case .welcome, .configure, .done: ""
        }
    }
}
