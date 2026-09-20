import Core
import Yams

/// Reads a vault note's YAML frontmatter back out: the pure, symmetric
/// counterpart to `FrontmatterRenderer.render(meeting:)`. Checks
/// `auricle.schema_version` before touching any other field and dispatches
/// to a version-specific parser, so a future schema bump adds a new parser
/// alongside this one rather than replacing it -- every historical version
/// ever shipped must stay readable.
public enum FrontmatterReader {
    public enum ReadError: Error {
        /// No `auricle.schema_version` to dispatch on -- the note has no
        /// frontmatter block, or its block has no `auricle:` mapping, or the
        /// key is missing under it.
        case notAnAuricleNote
        case schemaVersionTooOld(found: Int, oldestSupported: Int)
        case schemaVersionTooNew(found: Int, newestSupported: Int)
        case malformedFrontmatter(reason: String)
    }

    /// `FrontmatterRenderer`'s v1 schema, narrowed to what a caller of this
    /// reader (the future `--reattribute` speaker-prefill path) actually
    /// needs: identity (`meetingID`, `supersedes`) and `attendees`. `date`,
    /// `title`, and `tags` are excluded -- no named consumer needs them, and
    /// `date` in particular is the schema's one unquoted scalar, so a
    /// tag-driven decode (rather than this reader's literal-text `Node`
    /// accessors) would hand back a `Date` where a `String` was expected.
    public struct FrontmatterV1: Sendable, Equatable {
        public let meetingID: MeetingID
        public let schemaVersion: Int
        public let attendees: [String]
        public let supersedes: String?

        public init(meetingID: MeetingID, schemaVersion: Int, attendees: [String], supersedes: String?) {
            self.meetingID = meetingID
            self.schemaVersion = schemaVersion
            self.attendees = attendees
            self.supersedes = supersedes
        }
    }

    /// `oldestSupportedSchemaVersion` only moves if a version is ever formally
    /// desupported. The newest bound is `FrontmatterSchema.current`, the
    /// version the app writes, so widening what the app writes widens what
    /// this reader accepts; the bump also needs a new parser alongside `parseV1`.
    private static let oldestSupportedSchemaVersion = 1
    private static let newestSupportedSchemaVersion = FrontmatterSchema.current

    /// Pure: no file I/O. Throws `ReadError`, never a raw `YamlError`.
    public static func read(noteContents: String) throws -> FrontmatterV1 {
        let frontmatterYAML = try extractFrontmatterYAML(from: noteContents)
        let root = try composeRoot(from: frontmatterYAML)

        guard let auricle = root["auricle"], let schemaVersionNode = auricle["schema_version"] else {
            throw ReadError.notAnAuricleNote
        }
        guard let schemaVersion = schemaVersionNode.int else {
            throw ReadError.malformedFrontmatter(reason: "auricle.schema_version is present but not an integer scalar")
        }
        guard schemaVersion >= oldestSupportedSchemaVersion else {
            throw ReadError.schemaVersionTooOld(found: schemaVersion, oldestSupported: oldestSupportedSchemaVersion)
        }
        guard schemaVersion <= newestSupportedSchemaVersion else {
            throw ReadError.schemaVersionTooNew(found: schemaVersion, newestSupported: newestSupportedSchemaVersion)
        }

        return try parseV1(root: root, auricle: auricle)
    }

    // MARK: - Fence extraction

    /// Locates the frontmatter block by its `---` fence pair -- the exact
    /// shape `FrontmatterRenderer.render` emits -- before any YAML parsing
    /// happens. The note body below the closing fence (headings, `> ` quote
    /// blocks, arbitrary prose) is never handed to the YAML parser, which
    /// would otherwise read at least part of it as a second document.
    ///
    /// Tolerates what editors add around the block: a leading UTF-8 BOM, and
    /// trailing spaces or tabs on a fence line. A note whose first line is
    /// not a fence has no frontmatter at all, so it is not one of ours; a
    /// block that opens and never closes is damaged, so it is malformed.
    private static func extractFrontmatterYAML(from noteContents: String) throws -> String {
        let normalized = withoutByteOrderMark(noteContents).replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        guard let firstLine = lines.first, isFence(firstLine) else {
            throw ReadError.notAnAuricleNote
        }
        guard let closingFenceIndex = lines.dropFirst().firstIndex(where: isFence) else {
            throw ReadError.malformedFrontmatter(reason: "frontmatter is missing its closing fence")
        }
        return lines[1 ..< closingFenceIndex].joined(separator: "\n")
    }

    private static func withoutByteOrderMark(_ text: String) -> String {
        guard text.unicodeScalars.first == "\u{FEFF}" else {
            return text
        }
        return String(text.unicodeScalars.dropFirst())
    }

    private static func isFence(_ line: Substring) -> Bool {
        line.hasPrefix("---") && line.dropFirst(3).allSatisfy { $0 == " " || $0 == "\t" }
    }

    // MARK: - YAML composition

    /// `Yams.compose`, not `Yams.load`: this reads `Node` directly via its
    /// literal-text typed accessors (`.string`, `.int`, `.sequence`), the
    /// same low-level API `FrontmatterRenderer` builds its output with,
    /// rather than Yams' tag-driven `Any` construction (`Yams.load`), which
    /// resolves an unquoted scalar like `date` to a `Date` instead of a
    /// `String`.
    private static func composeRoot(from yaml: String) throws -> Node {
        do {
            guard let node = try Yams.compose(yaml: yaml) else {
                throw ReadError.notAnAuricleNote
            }
            return node
        } catch let error as ReadError {
            throw error
        } catch {
            throw ReadError.malformedFrontmatter(reason: "\(error)")
        }
    }

    // MARK: - v1

    private static func parseV1(root: Node, auricle: Node) throws -> FrontmatterV1 {
        guard let meetingIDString = auricle["meeting_id"]?.string,
              let meetingID = MeetingID(ulid: meetingIDString)
        else {
            throw ReadError.malformedFrontmatter(reason: "auricle.meeting_id is missing or not a well-formed ULID")
        }
        let attendees = try decodeAttendees(from: root)
        let supersedes = try decodeSupersedes(from: auricle)

        return FrontmatterV1(
            meetingID: meetingID,
            schemaVersion: 1,
            attendees: attendees,
            supersedes: supersedes,
        )
    }

    /// Absent or null `attendees` decodes to `[]` (Decision 2.4's calendar-
    /// enrichment-failed variant renders an empty list, not a missing key, but
    /// an older/foreign note may omit it entirely, and an editor may leave the
    /// key with no value). Present but not a sequence, or a sequence with a
    /// non-string element, fails loud rather than silently dropping data --
    /// the same posture as the `meeting_id` guard.
    private static func decodeAttendees(from root: Node) throws -> [String] {
        guard let attendeesNode = root["attendees"], !isNull(attendeesNode) else {
            return []
        }
        guard let attendeesSequence = attendeesNode.sequence else {
            throw ReadError.malformedFrontmatter(reason: "attendees is present but not a sequence")
        }
        return try attendeesSequence.map { element in
            guard let value = element.string else {
                throw ReadError.malformedFrontmatter(reason: "attendees contains a non-string element")
            }
            return value
        }
    }

    /// Absent or null `supersedes` decodes to `nil` (the common case: most
    /// notes are not a re-publish). Present but not a scalar fails loud rather
    /// than silently discarding lineage data.
    private static func decodeSupersedes(from auricle: Node) throws -> String? {
        guard let supersedesNode = auricle["supersedes"], !isNull(supersedesNode) else {
            return nil
        }
        guard let value = supersedesNode.string else {
            throw ReadError.malformedFrontmatter(reason: "auricle.supersedes is present but not a string scalar")
        }
        return value
    }

    /// True for an empty value, `~`, or an unquoted `null`. `Node.null` only
    /// recognizes plain-style scalars, so a quoted `"null"` -- a real string --
    /// is not null. `Node.string` alone can't tell the two apart.
    private static func isNull(_ node: Node) -> Bool {
        node.null != nil
    }
}
