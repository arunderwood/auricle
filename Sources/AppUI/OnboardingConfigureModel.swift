import Core
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
    /// The `self.wikilink` field's text as the user edits it. Starts at the
    /// configured value, else `defaultSelfWikilink(fullUserName:)`.
    public var selfWikilinkText: String
    /// The last `confirmSelfWikilink()` refusal, if any. Cleared on success.
    public private(set) var selfWikilinkError: SelfWikilinkError?
    /// The confirmed `[[…]]` value `finish()` writes; `nil` until confirmed.
    public private(set) var selfWikilink: String?
    /// The chosen vault's page names, empty until `loadVaultTerms()` returns.
    public private(set) var vaultTerms = Glossary()

    private static let maxSuggestions = 5

    private let opener: URLOpener
    private let validateVaultPath: @Sendable (URL) throws -> Void
    private let writeVaultPath: @Sendable (URL) throws -> Void
    private let writeAPIKey: @Sendable (String) throws -> Void
    private let writeSelfWikilink: @Sendable (String) throws -> Void
    private let configuredVaultPath: @Sendable () -> URL?
    private let loadTerms: @Sendable (URL) async -> Glossary

    /// - Parameter vaultTerms: Returns the page names of the vault at the
    ///   given path. `loadVaultTerms()` awaits it from the main actor, so an
    ///   implementation that walks the vault must do that work off it.
    public init(
        opener: @escaping URLOpener,
        validateVaultPath: @escaping @Sendable (URL) throws -> Void,
        writeVaultPath: @escaping @Sendable (URL) throws -> Void,
        writeAPIKey: @escaping @Sendable (String) throws -> Void,
        configuredVaultPath: @escaping @Sendable () -> URL?,
        writeSelfWikilink: @escaping @Sendable (String) throws -> Void,
        configuredSelfWikilink: @escaping @Sendable () -> String?,
        fullUserName: String,
        vaultTerms: @escaping @Sendable (URL) async -> Glossary,
    ) {
        self.opener = opener
        self.validateVaultPath = validateVaultPath
        self.writeVaultPath = writeVaultPath
        self.writeAPIKey = writeAPIKey
        self.configuredVaultPath = configuredVaultPath
        self.writeSelfWikilink = writeSelfWikilink
        loadTerms = vaultTerms
        selfWikilinkText = configuredSelfWikilink() ?? Self.defaultSelfWikilink(fullUserName: fullUserName)
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

    /// `[[<fullUserName>]]` sanitized by `SelfWikilink.fromName`, or empty
    /// when nothing of the name remains — an empty field asks the user to
    /// type one rather than suggesting `[[]]`.
    public static func defaultSelfWikilink(fullUserName: String) -> String {
        SelfWikilink.fromName(fullUserName).map { "[[\($0)]]" } ?? ""
    }

    /// Reads the validated vault's page names for `selfWikilinkSuggestions`.
    /// A no-op before a vault path has validated.
    public func loadVaultTerms() async {
        guard let vaultPath else { return }
        vaultTerms = await loadTerms(vaultPath)
    }

    /// Up to five vault page names matching the field's text: `people` before
    /// `uncategorized` (projects and concepts never name a person), then a
    /// prefix match on the name or any of its words before a substring match,
    /// then alphabetical. The name already in the field is left out.
    public var selfWikilinkSuggestions: [String] {
        let query = Self.linkTarget(of: selfWikilinkText).lowercased()
        guard !query.isEmpty else { return [] }
        let current = selfWikilinkText.trimmingCharacters(in: .whitespacesAndNewlines)

        var seen = Set<String>()
        var ranked: [RankedSuggestion] = []
        for (group, names) in [vaultTerms.people, vaultTerms.uncategorized].enumerated() {
            for name in names where seen.insert(name).inserted && current != "[[\(name)]]" {
                guard let rank = Self.matchRank(of: name, for: query) else { continue }
                ranked.append(RankedSuggestion(group: group, rank: rank, name: name))
            }
        }
        return ranked
            .sorted(by: RankedSuggestion.precedes)
            .prefix(Self.maxSuggestions)
            .map(\.name)
    }

    /// Replaces the field's text with `[[name]]`.
    public func selectSuggestion(_ name: String) {
        selfWikilinkText = "[[\(name)]]"
    }

    /// Normalizes the field through `SelfWikilink.normalized`, stores the
    /// result for `finish()`, and advances. Throws, stays on this sub-step,
    /// and records `selfWikilinkError` when the value is refused.
    public func confirmSelfWikilink() throws {
        let link: String
        do {
            link = try SelfWikilink.normalized(selfWikilinkText)
        } catch {
            selfWikilinkError = error
            throw error
        }
        selfWikilinkError = nil
        selfWikilink = link
        selfWikilinkText = link
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

    /// Writes the validated vault path, then the confirmed `self.wikilink`
    /// when there is one, to `~/.auricle/config.toml`.
    /// `OnboardingCoordinator.completeOnboarding()` calls this exactly once.
    public func finish() throws {
        guard let vaultPath else { throw FinishError.vaultPathNotSelected }
        try writeVaultPath(vaultPath)
        if let selfWikilink {
            try writeSelfWikilink(selfWikilink)
        }
    }

    private struct RankedSuggestion {
        /// 0 for `people`, 1 for `uncategorized`.
        let group: Int
        /// 0 for a prefix match, 1 for a substring match.
        let rank: Int
        let name: String

        static func precedes(_ lhs: Self, _ rhs: Self) -> Bool {
            if lhs.group != rhs.group {
                return lhs.group < rhs.group
            }
            if lhs.rank != rhs.rank {
                return lhs.rank < rhs.rank
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// The text with surrounding whitespace, one leading `[[`, one trailing
    /// `]]` and any `|alias` removed — what the user means to link to.
    private static func linkTarget(of text: String) -> String {
        var target = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if target.hasPrefix("[[") {
            target = target.dropFirst(2)
        }
        if target.hasSuffix("]]") {
            target = target.dropLast(2)
        }
        if let bar = target.firstIndex(of: "|") {
            target = target[..<bar]
        }
        return target.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 0 for a case-insensitive prefix match on the whole name or any word,
    /// 1 for a substring match, `nil` for no match. `query` is lowercased.
    private static func matchRank(of name: String, for query: String) -> Int? {
        let lowered = name.lowercased()
        if lowered.hasPrefix(query) || lowered.split(whereSeparator: \.isWhitespace).contains(where: { $0.hasPrefix(query) }) {
            return 0
        }
        return lowered.contains(query) ? 1 : nil
    }

    private func advanceSubStep() {
        let steps = ConfigureSubStep.allCases
        guard let index = steps.firstIndex(of: subStep), index + 1 < steps.count else { return }
        subStep = steps[index + 1]
    }
}
