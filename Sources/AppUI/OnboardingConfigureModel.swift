import Foundation
import Observation

/// Opens a URL through the OS and reports whether it reported success.
/// `AuricleApp` supplies `NotificationDelegate.openInDefaultApp` as the
/// production implementation; tests inject a canned closure so no URL is
/// ever actually opened.
public typealias URLOpener = @Sendable (URL) async -> Bool

/// A vault path failed `validateVaultPath`. Mirrors `VaultWriter.WriteError`'s
/// two relevant cases without depending on `Persist` from `AppUI` — the
/// composition root translates between them.
public enum VaultPathValidationError: Error, Sendable, Equatable {
    case missing(path: String)
    case notWritable(path: String)
    case other(String)
}

/// The Configure step's sub-steps, advanced in this order as each completes.
/// `.selfWikilink` is an inert placeholder: no view renders anything for it
/// and `advancePastSelfWikilinkPlaceholder()` is the only way through it,
/// until a real one is registered here.
public enum ConfigureSubStep: CaseIterable, Sendable, Equatable {
    case vaultPath
    case selfWikilink
    case obsidian
    case apiKey
    case expectations
}

/// Owns every Configure sub-step's data, validation, and advance decision —
/// `ConfigureStepView` only renders the current `subStep` and forwards user
/// actions here.
@MainActor @Observable
public final class OnboardingConfigureModel {
    /// Raised by `finish()` when it is called before a vault path has
    /// validated — the sub-step sequence never reaches `finish()` without
    /// one, so this only fires if a caller skips that gate.
    public enum FinishError: Error, Sendable, Equatable {
        case vaultPathNotSelected
    }

    public private(set) var subStep = ConfigureSubStep.vaultPath
    /// `nil` until the Obsidian check runs; then whether the opener reported
    /// success. Drives the non-blocking "Install Obsidian" message — the
    /// check never fails the step.
    public private(set) var obsidianOpened: Bool?
    /// The last vault-path validation failure, if any. Cleared once a path
    /// validates.
    public private(set) var vaultPathError: VaultPathValidationError?
    /// The validated vault path, once one has passed `validateVaultPath`.
    public private(set) var vaultPath: URL?

    private let opener: URLOpener
    private let validateVaultPath: @Sendable (URL) throws -> Void
    private let writeVaultPath: @Sendable (URL) throws -> Void
    private let writeAPIKey: @Sendable (String) throws -> Void
    private let configuredVaultPath: @Sendable () -> URL?

    public init(
        opener: @escaping URLOpener,
        validateVaultPath: @escaping @Sendable (URL) throws -> Void,
        writeVaultPath: @escaping @Sendable (URL) throws -> Void,
        writeAPIKey: @escaping @Sendable (String) throws -> Void,
        configuredVaultPath: @escaping @Sendable () -> URL?,
    ) {
        self.opener = opener
        self.validateVaultPath = validateVaultPath
        self.writeVaultPath = writeVaultPath
        self.writeAPIKey = writeAPIKey
        self.configuredVaultPath = configuredVaultPath
    }

    /// Prefills the picker at the configured vault path, or
    /// `~/checkouts/SecondBrain` (AR-DATA-9) when none is set yet — a prefill
    /// only, never written unless the user confirms a folder.
    public var defaultVaultDirectory: URL {
        configuredVaultPath() ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("checkouts/SecondBrain", isDirectory: true)
    }

    /// Validates `path` (an existing, writable directory) without creating
    /// the vault or a meetings subdirectory — the picker never creates
    /// anything — and advances past the picker on success. Throws and
    /// leaves `vaultPath` unset on a validation failure.
    public func selectVaultPath(_ path: URL) throws {
        do {
            try validateVaultPath(path)
        } catch let error as VaultPathValidationError {
            vaultPathError = error
            throw error
        }
        vaultPathError = nil
        vaultPath = path
        advanceSubStep()
    }

    /// Advances past the inert self.wikilink placeholder.
    public func advancePastSelfWikilinkPlaceholder() {
        advanceSubStep()
    }

    /// Opens `obsidian://open?vault=<name>` for the validated vault path's
    /// own directory name. Never fails the step — the result only drives the
    /// non-blocking "Install Obsidian" message. Does not itself advance;
    /// `continueFromObsidian()` does once the result has been shown.
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

    /// Advances past the Obsidian sub-step once its result has been shown.
    public func continueFromObsidian() {
        advanceSubStep()
    }

    /// Stores a trimmed `key` in Keychain and advances. Trimming matters
    /// because a key pasted with surrounding whitespace would otherwise
    /// fail Anthropic's auth silently at summarization time.
    public func setAPIKey(_ key: String) throws {
        try writeAPIKey(key.trimmingCharacters(in: .whitespacesAndNewlines))
        advanceSubStep()
    }

    /// Skips the API key sub-step, leaving Keychain untouched.
    public func skipAPIKey() {
        advanceSubStep()
    }

    /// Writes the validated vault path to `~/.auricle/config.toml`.
    /// `OnboardingCoordinator.completeOnboarding()` calls this exactly once.
    public func finish() throws {
        guard let vaultPath else { throw FinishError.vaultPathNotSelected }
        try writeVaultPath(vaultPath)
    }

    private func advanceSubStep() {
        let steps = ConfigureSubStep.allCases
        guard let index = steps.firstIndex(of: subStep), index + 1 < steps.count else { return }
        subStep = steps[index + 1]
    }
}
