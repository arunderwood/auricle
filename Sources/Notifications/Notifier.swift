import Core
import Foundation

/// Tells the maintainer a note is published. Implementations report their own
/// failures (a denied permission, a closed pipe) and never throw: the notify
/// stage must reach `awaiting_verification` whether or not anyone was told.
public protocol Notifier: Sendable {
    /// `vaultPath` is the absolute note path from `meetings.vault_note_path`.
    func fire(meetingID: MeetingID, title: String, vaultPath: String) async
}

/// The `userInfo` a posted notification carries, so a click can find the
/// meeting again. snake_case because it is a persisted wire shape that an
/// older build's notification may still deliver to a newer one.
public struct NotificationPayload: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let currentPayloadVersion = 1

    public let meetingID: String
    public let schemaVersion: Int
    public let payloadVersion: Int

    enum CodingKeys: String, CodingKey {
        case meetingID = "meeting_id"
        case schemaVersion = "schema_version"
        case payloadVersion = "payload_version"
    }

    public init(
        meetingID: String,
        schemaVersion: Int = NotificationPayload.currentSchemaVersion,
        payloadVersion: Int = NotificationPayload.currentPayloadVersion,
    ) {
        self.meetingID = meetingID
        self.schemaVersion = schemaVersion
        self.payloadVersion = payloadVersion
    }

    /// The property-list dictionary `UNNotificationContent.userInfo` expects.
    public var userInfo: [String: any Sendable] {
        [
            CodingKeys.meetingID.rawValue: meetingID,
            CodingKeys.schemaVersion.rawValue: schemaVersion,
            CodingKeys.payloadVersion.rawValue: payloadVersion,
        ]
    }

    /// Nil when `userInfo` is not shaped like a payload at all. A payload
    /// from a newer `payload_version` still decodes; the caller decides
    /// whether it can act on it.
    public init?(userInfo: [AnyHashable: Any]) {
        guard
            let meetingID = userInfo[CodingKeys.meetingID.rawValue] as? String,
            let schemaVersion = userInfo[CodingKeys.schemaVersion.rawValue] as? Int,
            let payloadVersion = userInfo[CodingKeys.payloadVersion.rawValue] as? Int
        else { return nil }
        self.init(meetingID: meetingID, schemaVersion: schemaVersion, payloadVersion: payloadVersion)
    }
}

/// Builds `obsidian://open` URLs from a note's absolute path.
public enum ObsidianURL {
    /// `obsidian://open?vault=<vault folder name>&file=<vault-relative path
    /// without .md>`. A note outside `vaultRoot` has no vault-relative name,
    /// so it falls back to `obsidian://open?path=<absolute path>`, which
    /// Obsidian resolves against whichever vault contains the file.
    /// Paths are normalized as strings, not through `URL`, which would rewrite
    /// non-ASCII names into decomposed form and no longer match the file on disk.
    public static func make(notePath: String, vaultRoot: URL) -> URL? {
        let root = (vaultRoot.path as NSString).standardizingPath
        let note = (notePath as NSString).standardizingPath
        let rootPrefix = root.hasSuffix("/") ? root : root + "/"

        guard note.hasPrefix(rootPrefix), note.count > rootPrefix.count else {
            guard let path = encode(note) else { return nil }
            return URL(string: "obsidian://open?path=\(path)")
        }

        var relative = String(note.dropFirst(rootPrefix.count))
        if relative.lowercased().hasSuffix(".md") {
            relative.removeLast(3)
        }
        let vaultName = (root as NSString).lastPathComponent
        guard let vault = encode(vaultName), let file = encode(relative) else { return nil }
        return URL(string: "obsidian://open?vault=\(vault)&file=\(file)")
    }

    /// Unreserved characters plus `/`: everything else, including `&`, `=`,
    /// `+` and `#`, would corrupt the query if left literal.
    private static let allowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/",
    )

    private static func encode(_ value: String) -> String? {
        value.addingPercentEncoding(withAllowedCharacters: allowed)
    }
}
