import AppKit
import AppUI
import SwiftUI

/// Renders the current `ConfigureSubStep` and forwards user actions to
/// `OnboardingConfigureModel` — sub-step sequencing, validation, and the
/// default-vault-path rule all live in that model, not here.
struct ConfigureStepView: View {
    let coordinator: OnboardingCoordinator

    @State private var apiKeyText = ""
    @State private var apiKeyError: String?

    var body: some View {
        VStack(spacing: 20) {
            switch coordinator.configure.subStep {
            case .vaultPath:
                vaultPathSubStep
            case .selfWikilink:
                selfWikilinkSubStep
            case .obsidian:
                obsidianSubStep
            case .apiKey:
                apiKeySubStep
            case .expectations:
                expectationsSubStep
            }
        }
        .padding(32)
    }

    private var vaultPathSubStep: some View {
        VStack(spacing: 12) {
            Text("Where's your Obsidian vault?")
                .font(.title2)
            if let vaultPathError = coordinator.configure.vaultPathError {
                Text(message(for: vaultPathError))
                    .foregroundStyle(.red)
            }
            Button("Choose Vault Folder…") {
                chooseVaultFolder()
            }
            .accessibilityLabel("Choose Vault Folder")
            .buttonStyle(.borderedProminent)
        }
    }

    /// Inert until a real sub-step is registered here — see
    /// `ConfigureSubStep.selfWikilink`'s doc comment.
    private var selfWikilinkSubStep: some View {
        Button("Continue") {
            coordinator.configure.advancePastSelfWikilinkPlaceholder()
        }
        .accessibilityLabel("Continue")
        .buttonStyle(.borderedProminent)
    }

    private var obsidianSubStep: some View {
        VStack(spacing: 12) {
            Text("Let's confirm Obsidian can open your vault")
                .font(.title2)
            if let obsidianOpened = coordinator.configure.obsidianOpened {
                if !obsidianOpened {
                    Text("Install Obsidian to use auricle's vault output")
                        .foregroundStyle(.secondary)
                }
                Button("Continue") {
                    coordinator.configure.continueFromObsidian()
                }
                .accessibilityLabel("Continue")
                .buttonStyle(.borderedProminent)
            } else {
                Button("Open in Obsidian") {
                    Task {
                        await coordinator.configure.checkObsidian()
                    }
                }
                .accessibilityLabel("Open in Obsidian")
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var apiKeySubStep: some View {
        VStack(spacing: 12) {
            Text("Add your Anthropic API key")
                .font(.title2)
            SecureField("API Key", text: $apiKeyText)
                .accessibilityLabel("Anthropic API Key")
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
            if let apiKeyError {
                Text(apiKeyError)
                    .foregroundStyle(.red)
            }
            HStack {
                Button("Skip") {
                    coordinator.configure.skipAPIKey()
                }
                .accessibilityLabel("Skip API key")
                Button("Save") { saveAPIKey() }
                    .accessibilityLabel("Save API key")
                    .disabled(apiKeyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var expectationsSubStep: some View {
        VStack(spacing: 12) {
            Text("Start a recording before your meeting and stop it after; you'll get a notification when the summary is ready")
                .font(.title2)
                .multilineTextAlignment(.center)
            Button("Finish") {
                coordinator.advance()
            }
            .accessibilityLabel("Finish")
            .buttonStyle(.borderedProminent)
        }
    }

    private func chooseVaultFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = coordinator.configure.defaultVaultDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // `selectVaultPath` records a failure on `coordinator.configure.vaultPathError`,
        // which `vaultPathSubStep` renders; staying on this sub-step is the point.
        try? coordinator.configure.selectVaultPath(url)
    }

    private func saveAPIKey() {
        do {
            try coordinator.configure.setAPIKey(apiKeyText)
        } catch {
            apiKeyError = "Couldn't save the API key. Try again."
        }
    }

    private func message(for error: VaultPathValidationError) -> String {
        switch error {
        case let .missing(path):
            "\(path) doesn't exist or isn't a folder."
        case let .notWritable(path):
            "\(path) isn't writable."
        case .other:
            "That folder can't be used."
        }
    }
}
