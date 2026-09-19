import Foundation

/// Turns a `MeetingForFilename` into the deterministic vault filename
/// Decision 2.4 specifies: `<captureDate>-<slug>.md`, or
/// `<captureDate>-<slug>-<ordinal>.md` for a same-day, same-slug collision.
/// Pure and synchronous — no filesystem access, no `Date`/`Calendar`/
/// `TimeZone` reads. Collision *detection* (deciding which `ordinal` to
/// pass) is `VaultWriter`'s job (Story 2.3); this only formats the ordinal
/// it's given.
public enum FilenameResolver {
    private static let calendarTitleCap = 60
    private static let attendeeNameCap = 25
    private static let maxJoinedAttendees = 2

    public static func resolve(meeting: MeetingForFilename, ordinal: Int? = nil) -> String {
        let suffix = if let ordinal, ordinal >= 2 {
            "-\(ordinal)"
        } else {
            ""
        }
        return "\(meeting.captureDate)-\(slug(for: meeting))\(suffix).md"
    }

    // MARK: - Slug priority chain

    private static func slug(for meeting: MeetingForFilename) -> String {
        if let calendarEventTitle = meeting.calendarEventTitle {
            let titleSlug = normalize(calendarEventTitle, cap: calendarTitleCap)
            if !titleSlug.isEmpty {
                return titleSlug
            }
        }
        if let attendeeSlug = attendeeSlug(for: meeting) {
            return attendeeSlug
        }
        // The chain ends here because this slug is never empty: the literal
        // "meeting-at-" prefix is 11 characters whatever captureTime24h holds.
        return "meeting-at-\(meeting.captureTime24h)"
    }

    /// Source 2: `with-<other-1>[-and-<other-2>]`, built from named
    /// attendees with `selfWikilink` filtered out. Each surviving name is
    /// normalized with a 25-character cap *before* joining — not the
    /// assembled string truncated after — so the joined result can never
    /// exceed 60 characters by construction (`with-` + 25 + `-and-` + 25 =
    /// 60 in the 2-name case) and a single long hyphen-free name can never
    /// collapse the slug down to the bare glue word `with`. Returns `nil`
    /// (fall through to source 3) when 0, or more than 2, names survive.
    private static func attendeeSlug(for meeting: MeetingForFilename) -> String? {
        let others = meeting.attendees.filter { $0 != meeting.selfWikilink }
        let normalizedNames = others
            .map { normalize($0, cap: attendeeNameCap) }
            .filter { !$0.isEmpty }
        guard (1 ... maxJoinedAttendees).contains(normalizedNames.count) else {
            return nil
        }
        return "with-" + normalizedNames.joined(separator: "-and-")
    }

    // MARK: - Normalization pipeline

    /// Decision 2.4's 8-step slug normalization: NFKD-decompose, strip
    /// non-ASCII, lowercase, collapse non-`[a-z0-9]` runs to a single
    /// hyphen, trim and collapse hyphens, then cap at `cap` characters at a
    /// hyphen boundary. Applied to a whole candidate string (source 1) or
    /// to a single attendee name before joining (source 2). Each name is
    /// normalized and capped before joining because truncating the
    /// assembled slug can land on the hyphen after `with-` and leave the
    /// bare word `with`.
    private static func normalize(_ input: String, cap: Int) -> String {
        let decomposed = input.decomposedStringWithCompatibilityMapping
        let asciiOnly = String(String.UnicodeScalarView(decomposed.unicodeScalars.filter(\.isASCII)))
        let lowercased = asciiOnly.lowercased()
        let kebab = lowercased.replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        let trimmed = kebab.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let collapsed = trimmed.replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        return truncate(collapsed, cap: cap)
    }

    /// Cuts at the last hyphen at or before `cap` characters (dropping the
    /// hyphen), so the primary path never splits a word mid-token. Falls
    /// back to a hard cut at `cap` only when no hyphen exists in that
    /// window — Decision 2.4's own documented exception to "never cut
    /// mid-word".
    private static func truncate(_ string: String, cap: Int) -> String {
        guard string.count > cap else {
            return string
        }
        let prefix = String(string.prefix(cap))
        guard let lastHyphen = prefix.lastIndex(of: "-") else {
            return prefix
        }
        return String(prefix[..<lastHyphen])
    }
}
