import AppUI
import SwiftUI

/// Shared screen for the three permission steps. Renders
/// `coordinator.permissionContent` and forwards every tap to
/// `coordinator.perform(_:)`; which copy and buttons appear is decided in
/// `PermissionStepContent`, not here.
struct PermissionStepView: View {
    let coordinator: OnboardingCoordinator

    /// Guards against a second tap starting a second action while the first
    /// is still in flight, which could advance past a whole permission step
    /// the user never actually saw a result for.
    @State private var isPerforming = false

    var body: some View {
        if let content = coordinator.permissionContent {
            VStack(spacing: 16) {
                Text(content.title)
                    .font(.title2)
                Text(content.whyLine)
                    .multilineTextAlignment(.center)
                if let standingNote = content.standingNote {
                    Text(standingNote)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if let followUp = content.followUp {
                    Text(followUp)
                        .multilineTextAlignment(.center)
                }
                HStack(spacing: 12) {
                    ForEach(content.actions, id: \.self) { action in
                        actionButton(action, content: content)
                    }
                }
                if let skipCaption = content.skipCaption {
                    Text(skipCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 480)
            .padding(32)
        }
    }

    /// The last action is the forward one (request, Try Again, Skip or
    /// Continue), so it gets the prominent style.
    @ViewBuilder
    private func actionButton(_ action: PermissionStepAction, content: PermissionStepContent) -> some View {
        let title = title(for: action, content: content)
        let button = Button(title) {
            guard !isPerforming else { return }
            isPerforming = true
            Task {
                await coordinator.perform(action)
                isPerforming = false
            }
        }
        .accessibilityLabel(title)
        .disabled(isPerforming)
        if action == content.actions.last {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private func title(for action: PermissionStepAction, content: PermissionStepContent) -> String {
        switch action {
        case .request: content.requestButtonTitle
        case .openSettings: "Open Settings"
        case .skip: "Skip"
        case .tryAgain: "Try Again"
        case .continueOnward: "Continue"
        }
    }
}
