import AppUI
import SwiftUI

/// The onboarding narrative's opening screen: names the four steps ahead
/// without firing any TCC prompt (the permission steps prompt only when
/// their own button is pressed).
struct WelcomeStepView: View {
    let coordinator: OnboardingCoordinator

    var body: some View {
        VStack(spacing: 20) {
            Text("Let's get auricle set up — 4 quick steps")
                .font(.title2)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 8) {
                Label("Microphone", systemImage: "mic")
                Label("System Audio", systemImage: "speaker.wave.2")
                Label("Notifications", systemImage: "bell")
                Label("Configure", systemImage: "gearshape")
            }
            Button("Get Started") {
                coordinator.advance()
            }
            .accessibilityLabel("Get Started")
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }
}
