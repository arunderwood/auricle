import Foundation

/// Turns a `MeetingForFilename` into the deterministic vault filename
/// Decision 2.4 specifies: `<captureDate>-<slug>.md`, or
/// `<captureDate>-<slug>-<ordinal>.md` for a same-day, same-slug collision.
/// Pure and synchronous — no filesystem access, no `Date`/`Calendar`/
/// `TimeZone` reads. Collision *detection* (deciding which `ordinal` to
/// pass) is `VaultWriter`'s job (Story 2.3); this only formats the ordinal
/// it's given.
public enum FilenameResolver {
    private static let slugCap = 60
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
            let titleSlug = normalize(calendarEventTitle, cap: slugCap)
            if !titleSlug.isEmpty {
                return titleSlug
            }
        }
        if let attendeeSlug = attendeeSlug(for: meeting) {
            return attendeeSlug
        }
        // Normalized so a captureTime24h with path characters cannot reach the
        // filename. The chain ends here because the result is never empty:
        // "meeting-at" is hyphen-delimited ASCII, so it survives normalization
        // and the cap whatever captureTime24h holds.
        return normalize("meeting-at-\(meeting.captureTime24h)", cap: slugCap)
    }

    /// Source 2: `with-<other-1>[-and-<other-2>]`, built from named
    /// attendees with the self link's identity filtered out and repeated
    /// identities collapsed to their first occurrence (see `WikilinkParts`).
    /// Each surviving display name is normalized with a 25-character cap
    /// *before* joining — not the assembled string truncated after — so the
    /// joined result can never exceed 60 characters by construction (`with-` +
    /// 25 + `-and-` + 25 = 60 in the 2-name case) and a single long
    /// hyphen-free name can never collapse the slug down to the bare glue
    /// word `with`. Returns `nil` (fall through to source 3) when 0, or more
    /// than 2, names survive.
    private static func attendeeSlug(for meeting: MeetingForFilename) -> String? {
        let selfIdentity = meeting.selfWikilink.map { WikilinkParts($0).identity }
        var seenIdentities = Set<String>()
        let others = meeting.attendees
            .map { WikilinkParts($0) }
            .filter { $0.identity != selfIdentity }
            .filter { seenIdentities.insert($0.identity).inserted }
        let normalizedNames = others
            .map { normalize($0.displayName, cap: attendeeNameCap) }
            .filter { !$0.isEmpty }
        guard (1 ... maxJoinedAttendees).contains(normalizedNames.count) else {
            return nil
        }
        return "with-" + normalizedNames.joined(separator: "-and-")
    }

    /// The two things an attendee wikilink says, in Obsidian's own terms.
    /// `[[People/Ben Smith#Notes|Ben]]` has the target `People/Ben Smith`
    /// (heading and block suffixes dropped), the identity `ben smith` (the
    /// target's last path component, lowercased because Obsidian resolves
    /// links case-insensitively), and the display name `Ben` (the alias, or
    /// the last path component when there is none). Identity decides who is
    /// self and who is a duplicate; the display name feeds the slug.
    private struct WikilinkParts {
        let identity: String
        let displayName: String

        init(_ wikilink: String) {
            var inner = Substring(wikilink.trimmingCharacters(in: .whitespacesAndNewlines))
            if inner.hasPrefix("[[") {
                inner = inner.dropFirst(2)
            }
            if inner.hasSuffix("]]") {
                inner = inner.dropLast(2)
            }
            let pipe = inner.firstIndex(of: "|")
            let alias = pipe.map { inner[inner.index(after: $0)...].trimmingCharacters(in: .whitespaces) }
            let path = inner[..<(pipe ?? inner.endIndex)]
            let target = path.prefix { $0 != "#" && $0 != "^" }
            let name = (target.split(separator: "/", omittingEmptySubsequences: false).last ?? "")
                .trimmingCharacters(in: .whitespaces)
            identity = name.lowercased()
            displayName = if let alias, !alias.isEmpty {
                alias
            } else {
                name
            }
        }
    }

    // MARK: - Normalization pipeline

    /// Decision 2.4's slug normalization: map dash and space characters to a
    /// separator, transliterate the fixed set of letters NFKD cannot
    /// decompose, NFKD-decompose, strip non-ASCII, lowercase, collapse
    /// non-`[a-z0-9]` runs to a single hyphen, trim and collapse hyphens,
    /// then cap at `cap` characters at a hyphen boundary. Applied to a whole
    /// candidate string (source 1) or to a single attendee name before
    /// joining (source 2). Each name is normalized and capped before joining
    /// because truncating the assembled slug can land on the hyphen after
    /// `with-` and leave the bare word `with`.
    private static func normalize(_ input: String, cap: Int) -> String {
        let decomposed = separateAndTransliterate(input).decomposedStringWithCompatibilityMapping
        let asciiOnly = String(String.UnicodeScalarView(decomposed.unicodeScalars.filter(\.isASCII)))
        let lowercased = asciiOnly.lowercased()
        let kebab = lowercased.replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        let trimmed = kebab.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let collapsed = trimmed.replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        return truncate(collapsed, cap: cap)
    }

    /// Letters that have no NFKD decomposition and would otherwise be
    /// stripped as non-ASCII. A fixed table, not `CFStringTransform` or ICU
    /// transliteration: their output varies by OS version, and a filename
    /// must not change when the OS does.
    private static let transliterations: [Unicode.Scalar: String] = [
        "ß": "ss", "æ": "ae", "Æ": "AE", "œ": "oe", "Œ": "OE", "ø": "o", "Ø": "O",
        "đ": "d", "Đ": "D", "ð": "d", "Ð": "D", "þ": "th", "Þ": "Th", "ł": "l", "Ł": "L", "ı": "i",
    ]

    /// Runs ahead of NFKD and the non-ASCII strip. Dash punctuation and
    /// space separators separate words, so stripping them would fuse the
    /// words on either side (`Q3–Q4` → `q3q4`); each becomes a space, which
    /// the kebab step turns into a hyphen.
    private static func separateAndTransliterate(_ input: String) -> String {
        var output = String.UnicodeScalarView()
        for scalar in input.unicodeScalars {
            if isSeparator(scalar) {
                output.append(" ")
            } else if let replacement = transliterations[scalar] {
                output.append(contentsOf: replacement.unicodeScalars)
            } else {
                output.append(scalar)
            }
        }
        return String(output)
    }

    /// U+2212 (minus sign) is a math symbol, not dash punctuation, but titles
    /// use it as a dash, so it separates words too.
    private static func isSeparator(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .dashPunctuation, .spaceSeparator, .lineSeparator, .paragraphSeparator:
            true
        default:
            scalar == "\u{2212}"
        }
    }

    /// Cuts at the last hyphen at or before `cap` characters (dropping the
    /// hyphen), so the primary path never splits a word mid-token. When the
    /// character just past the cap is itself a hyphen, the first `cap`
    /// characters already end on a word boundary and are kept whole. Falls
    /// back to a hard cut at `cap` only when no hyphen exists in that
    /// window — Decision 2.4's own documented exception to "never cut
    /// mid-word".
    private static func truncate(_ string: String, cap: Int) -> String {
        guard string.count > cap else {
            return string
        }
        let prefix = string.prefix(cap)
        if string[prefix.endIndex] == "-" {
            return String(prefix)
        }
        guard let lastHyphen = prefix.lastIndex(of: "-") else {
            return String(prefix)
        }
        return String(prefix[..<lastHyphen])
    }
}
