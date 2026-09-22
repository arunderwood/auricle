import AppKit
import AppUI
import Core
import Persist
import SwiftUI

/// Sequences the Configure step's four sub-steps (vault path, Obsidian
/// check, API key, expectations) per Story 5.7's Configure AC. Which
/// sub-step is showing is this view's own local state; every validation and
/// side effect lives in `OnboardingConfigureModel`.
struct ConfigureStepView: View {
    private enum SubStep {
        case vaultPath, obsidian, apiKey, expectations
    }

    let coordinator: OnboardingCoordinator

    @State private var subStep = SubStep.vaultPath
    @State private var apiKeyText = ""
    @State private var apiKeyError: String?

    var body: some View {
        VStack(spacing: 20) {
            switch subStep {
            case .vaultPath:
                vaultPathSubStep
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
                    subStep = .apiKey
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
                    subStep = .expectations
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

    /// Prefills the picker at the configured `vault_path`, or
    /// `~/checkouts/SecondBrain` (AR-DATA-9) when none is set yet — a prefill
    /// only, never written unless the user confirms a folder.
    private func chooseVaultFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = defaultVaultDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try coordinator.configure.selectVaultPath(url)
            subStep = .obsidian
        } catch {
            // `selectVaultPath` already recorded the error on
            // `coordinator.configure.vaultPathError`, which `vaultPathSubStep`
            // renders; staying on this sub-step is the point.
        }
    }

    private func saveAPIKey() {
        do {
            try coordinator.configure.setAPIKey(apiKeyText)
            subStep = .expectations
        } catch {
            apiKeyError = "Couldn't save the API key. Try again."
        }
    }

    private var defaultVaultDirectory: URL {
        (try? Config.load())?.vaultPath
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("checkouts/SecondBrain", isDirectory: true)
    }

    private func message(for error: VaultWriter.WriteError) -> String {
        switch error {
        case let .vaultPathMissing(path):
            "\(path) doesn't exist or isn't a folder."
        case let .vaultPathNotWritable(path):
            "\(path) isn't writable."
        case .meetingsSubdirIsNotADirectory, .meetingsSubdirNotWritable, .meetingsSubdirCreationFailed, .collisionRetriesExhausted:
            "That folder can't be used."
        }
    }
}
