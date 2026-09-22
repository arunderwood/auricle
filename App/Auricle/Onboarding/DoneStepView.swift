import AppUI
import Core
import SwiftUI

/// Onboarding's closing state. `completeOnboarding()` runs on appear,
/// writing the marker and the vault path so later launches skip straight to
/// the app's normal root view. Both writes it makes
/// (`OnboardingConfigureModel.finish()`, `OnboardingMarker.write`) are
/// idempotent, so a failure here shows a retry rather than silently leaving
/// the user on a "You're set up" screen onboarding never actually finished.
struct DoneStepView: View {
    let coordinator: OnboardingCoordinator

    @State private var failureMessage: String?

    private let log = Log(category: "onboarding")

    var body: some View {
        Group {
            if let failureMessage {
                VStack(spacing: 12) {
                    Text("Couldn't finish setup")
                        .font(.title2)
                    Text(failureMessage)
                        .foregroundStyle(.secondary)
                    Button("Try Again") {
                        complete()
                    }
                    .accessibilityLabel("Try Again")
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Text("You're set up")
                    .font(.title2)
            }
        }
        .padding(32)
        .onAppear {
            complete()
        }
    }

    private func complete() {
        do {
            try coordinator.completeOnboarding()
            failureMessage = nil
        } catch {
            failureMessage = String(describing: error)
            log.error("failed to complete onboarding", ["error": .publicSafe(String(describing: error))])
        }
    }
}
