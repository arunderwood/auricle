import ClaudeSummarizer
import Core
import Foundation
import Observation
import Persist

/// Opens a URL through the OS and reports whether it reported success.
/// `AuricleApp` supplies `NotificationDelegate.openInDefaultApp` as the
/// production implementation; tests inject a canned closure so no URL is
/// ever actually opened.
public typealias URLOpener = @Sendable (URL) async -> Bool

/// The Configure step's four sub-steps (vault path, Obsidian check, API key,
/// expectations) per Story 5.7's Configure AC. Which sub-step is current is
/// `ConfigureStepView`'s own local state — this model only holds the
/// validated data and side effects each sub-step needs.
@MainActor @Observable
public final class OnboardingConfigureModel {
    /// Raised by `finish()` when it is called before a vault path has
    /// validated — `ConfigureStepView` never advances past the vault picker
    /// without one, so this only fires if a caller skips that gate.
    public enum FinishError: Error, Sendable, Equatable {
        case vaultPathNotSelected
    }

    /// `nil` until the Obsidian check runs; then whether the opener reported
    /// success. Drives the non-blocking "Install Obsidian" message — the
    /// check never fails the step.
    public private(set) var obsidianOpened: Bool?
    /// The last vault-path validation failure, if any. Cleared once a path
    /// validates.
    public private(set) var vaultPathError: VaultWriter.WriteError?
    /// The validated vault path, once one has passed `VaultWriter.validateVaultPath`.
    public private(set) var vaultPath: URL?

    private let opener: URLOpener
    private let writeVaultPath: @Sendable (URL) throws -> Void
    private let writeAPIKey: @Sendable (String) throws -> Void

    public init(
        opener: @escaping URLOpener,
        writeVaultPath: @escaping @Sendable (URL) throws -> Void = { try ConfigWriter.set("vault_path", to: $0.path) },
        writeAPIKey: @escaping @Sendable (String) throws -> Void = { try KeychainAPIKey.write($0) },
    ) {
        self.opener = opener
        self.writeVaultPath = writeVaultPath
        self.writeAPIKey = writeAPIKey
    }

    /// Validates `path` (an existing, writable directory) without creating
    /// the vault or a meetings subdirectory — the picker never creates
    /// anything. Throws and leaves `vaultPath` unset on a validation
    /// failure, so the caller knows not to advance past the picker.
    public func selectVaultPath(_ path: URL) throws {
        do {
            try VaultWriter.validateVaultPath(path)
        } catch let error as VaultWriter.WriteError {
            vaultPathError = error
            throw error
        }
        vaultPathError = nil
        vaultPath = path
    }

    /// Opens `obsidian://open?vault=<name>` for the validated vault path's
    /// own directory name. A `false` result only records `obsidianOpened`
    /// for the view's non-blocking message — this never throws and the
    /// caller always advances after it returns.
    public func checkObsidian() async {
        guard let vaultPath else { return }
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "vault", value: vaultPath.lastPathComponent)]
        guard let url = components.url else {
            obsidianOpened = false
            return
        }
        obsidianOpened = await opener(url)
    }

    /// Stores `key` in Keychain. Skipping this sub-step (never calling it)
    /// leaves Keychain untouched — there is no separate "skip" method.
    public func setAPIKey(_ key: String) throws {
        try writeAPIKey(key)
    }

    /// Writes the validated vault path to `~/.auricle/config.toml`.
    /// `OnboardingCoordinator.completeOnboarding()` calls this exactly once.
    public func finish() throws {
        guard let vaultPath else { throw FinishError.vaultPathNotSelected }
        try writeVaultPath(vaultPath)
    }
}
