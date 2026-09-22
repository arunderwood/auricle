import Foundation
import TOMLKit

public enum ConfigError: Error, Sendable, Equatable {
    /// The file exists but could not be read. Carries the Cocoa error code
    /// rather than its description, which embeds the file's path.
    case unreadable(code: Int)
    /// Not valid TOML, or not valid UTF-8. `line` is nil when the failure has
    /// no position.
    case malformed(line: Int?)
    /// Valid TOML whose value for `key` (dotted for nested tables) is unusable.
    case invalidValue(key: String, reason: String)
}

/// User-editable settings from `~/.auricle/config.toml` (FR59). Secrets never
/// live here (NFR-S1): the Anthropic API key and the Google refresh token stay
/// in Keychain. The Google client secret is the one credential-shaped value
/// this file may carry, because Google issues Desktop-type clients a secret it
/// documents as non-confidential.
///
/// Only keys a caller reads today have accessors. Keys the file carries that
/// this type does not know are ignored, so a newer file still loads.
///
/// An empty string means "unset" for every key, so a file written from a
/// template with blank values behaves like a file without them.
public struct Config: Sendable, Equatable {
    public static let defaultMeetingsSubdir = "Meetings"

    public struct GoogleCalendar: Sendable, Equatable {
        public let clientID: String?
        public let clientSecret: String?

        public init(clientID: String? = nil, clientSecret: String? = nil) {
            self.clientID = clientID
            self.clientSecret = clientSecret
        }
    }

    public struct Attribution: Sendable, Equatable {
        public static let defaultSnippetDurationSeconds = 8

        /// Any positive value is kept as written; the diarization stage clamps
        /// it to the range a snippet can usefully play.
        public let snippetDurationSeconds: Int

        public init(snippetDurationSeconds: Int = Attribution.defaultSnippetDurationSeconds) {
            self.snippetDurationSeconds = snippetDurationSeconds
        }
    }

    public struct DiarizationReview: Sendable, Equatable {
        public static let defaultModel = "claude-haiku-4-5"

        /// Off by default: the review is an unproven AI feature that costs
        /// money on every meeting.
        public let enabled: Bool
        public let model: String

        public init(enabled: Bool = false, model: String = DiarizationReview.defaultModel) {
            self.enabled = enabled
            self.model = model
        }
    }

    /// Absolute, tilde-expanded, and never defaulted: a default would have to
    /// name one person's vault, and an unset value means "no vault", which the
    /// summarize stage treats as an empty glossary.
    public let vaultPath: URL?
    /// Relative to `vaultPath`; never absolute and never climbs out of it.
    public let meetingsSubdir: String
    public let googleCalendar: GoogleCalendar
    public let attribution: Attribution
    public let diarizationReview: DiarizationReview
    /// The wikilink text (e.g. `"[[Jordan]]"`) identifying this user, in the
    /// vault's own wikilink syntax.
    public let selfWikilink: String?

    public init(
        vaultPath: URL? = nil,
        meetingsSubdir: String = Config.defaultMeetingsSubdir,
        googleCalendar: GoogleCalendar = GoogleCalendar(),
        attribution: Attribution = Attribution(),
        diarizationReview: DiarizationReview = DiarizationReview(),
        selfWikilink: String? = nil,
    ) {
        self.vaultPath = vaultPath
        self.meetingsSubdir = meetingsSubdir
        self.googleCalendar = googleCalendar
        self.attribution = attribution
        self.diarizationReview = diarizationReview
        self.selfWikilink = selfWikilink
    }

    public static func defaultFileURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory
            .appendingPathComponent(".auricle", isDirectory: true)
            .appendingPathComponent("config.toml", isDirectory: false)
    }

    /// A missing file is the defaults, not an error: nobody has to write a
    /// config to run. A file that exists but cannot be used throws, so a typo
    /// is never silently read as "unset".
    ///
    /// `homeDirectory` is what a leading `~` expands to. Both parameters exist
    /// so tests never read the real `~/.auricle`.
    public static func load(
        from fileURL: URL? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    ) throws -> Config {
        let url = fileURL ?? defaultFileURL(homeDirectory: homeDirectory)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return Config()
        } catch {
            throw ConfigError.unreadable(code: (error as NSError).code)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ConfigError.malformed(line: nil)
        }
        return try parse(text, homeDirectory: homeDirectory)
    }

    public static func parse(
        _ text: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    ) throws -> Config {
        let raw: RawConfig
        do {
            raw = try TOMLDecoder().decode(RawConfig.self, from: text)
        } catch let error as TOMLParseError {
            throw ConfigError.malformed(line: error.source.begin.line)
        } catch let error as DecodingError {
            throw invalidValue(from: error)
        }

        return try Config(
            vaultPath: vaultURL(raw.vaultPath, homeDirectory: homeDirectory),
            meetingsSubdir: meetingsSubdir(raw.meetingsSubdir),
            googleCalendar: GoogleCalendar(
                clientID: nonEmpty(raw.googleCalendar?.clientID),
                clientSecret: nonEmpty(raw.googleCalendar?.clientSecret),
            ),
            attribution: attribution(raw.attribution),
            diarizationReview: DiarizationReview(
                enabled: raw.diarizationReview?.enabled ?? false,
                model: nonEmpty(raw.diarizationReview?.model) ?? DiarizationReview.defaultModel,
            ),
            selfWikilink: nonEmpty(raw.selfTable?.wikilink),
        )
    }

    private static func attribution(_ raw: RawAttribution?) throws -> Attribution {
        guard let seconds = raw?.snippetDurationSeconds else { return Attribution() }
        guard seconds > 0 else {
            throw ConfigError.invalidValue(key: "attribution.snippet_duration_seconds", reason: "must be a positive number of seconds")
        }
        return Attribution(snippetDurationSeconds: seconds)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// Only a bare `~` or a `~/` prefix expands. Another user's `~name` has no
    /// meaning to a tool that reads one user's file, and falls through to the
    /// absolute-path check.
    private static func vaultURL(_ value: String?, homeDirectory: URL) throws -> URL? {
        guard let value = nonEmpty(value) else { return nil }
        let expanded = if value == "~" {
            homeDirectory.path
        } else if value.hasPrefix("~/") {
            "\(homeDirectory.path)/\(value.dropFirst(2))"
        } else {
            value
        }
        guard expanded.hasPrefix("/") else {
            throw ConfigError.invalidValue(key: "vault_path", reason: "must be an absolute path or start with ~/")
        }
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    private static func meetingsSubdir(_ value: String?) throws -> String {
        guard let value = nonEmpty(value) else { return defaultMeetingsSubdir }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !value.hasPrefix("/"), !components.contains("..") else {
            throw ConfigError.invalidValue(key: "meetings_subdir", reason: "must be a relative path inside the vault")
        }
        return value
    }

    private static func invalidValue(from error: DecodingError) -> ConfigError {
        let codingPath = switch error {
        case let .typeMismatch(_, context), let .valueNotFound(_, context), let .keyNotFound(_, context), let .dataCorrupted(context):
            context.codingPath
        @unknown default:
            [CodingKey]()
        }
        return .invalidValue(key: codingPath.map(\.stringValue).joined(separator: "."), reason: "has the wrong type")
    }
}

private struct RawGoogleCalendar: Decodable {
    let clientID: String?
    let clientSecret: String?

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case clientSecret = "client_secret"
    }
}

private struct RawAttribution: Decodable {
    let snippetDurationSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case snippetDurationSeconds = "snippet_duration_seconds"
    }
}

private struct RawDiarizationReview: Decodable {
    let enabled: Bool?
    let model: String?
}

/// Named `RawSelfTable` rather than `RawSelf`: `self` is a reserved word, so
/// the TOML table name `self` is carried instead in `RawConfig`'s
/// `CodingKeys`.
private struct RawSelfTable: Decodable {
    let wikilink: String?
}

private struct RawConfig: Decodable {
    let vaultPath: String?
    let meetingsSubdir: String?
    let googleCalendar: RawGoogleCalendar?
    let attribution: RawAttribution?
    let diarizationReview: RawDiarizationReview?
    let selfTable: RawSelfTable?

    enum CodingKeys: String, CodingKey {
        case vaultPath = "vault_path"
        case meetingsSubdir = "meetings_subdir"
        case googleCalendar = "google_calendar"
        case attribution
        case diarizationReview = "diarization_review"
        case selfTable = "self"
    }
}
