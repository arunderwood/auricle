import Foundation

/// A `self.wikilink` value that `SelfWikilink.normalized` refused.
public enum SelfWikilinkError: Error, Sendable, Equatable {
    /// Nothing is left once whitespace and a surrounding `[[`/`]]` are removed.
    case empty
    /// The link target carries a character with meaning inside `[[…]]`
    /// (`[ ] | # ^ \`), a newline, or a control character, so it cannot name
    /// exactly one page.
    case malformed

    /// Why the value was refused, for `ConfigError.invalidValue`'s `reason`.
    public var reason: String {
        switch self {
        case .empty: "must name a page"
        case .malformed: "must be one [[Page Name]] without an alias or any of [ ] | # ^ \\"
        }
    }
}

/// The one definition of a valid `self.wikilink`: a single `[[Page Name]]`
/// with no alias, heading or block reference. Config reading, config writing,
/// onboarding and the summarize stage all go through it, so a value one of
/// them accepts is a value every other one accepts in the same form.
public enum SelfWikilink {
    private static let syntaxCharacters = CharacterSet(charactersIn: "[]|#^\\")

    /// Accepts bare text or one wrapped `[[…]]` link and returns it as
    /// `[[target]]` with surrounding whitespace removed.
    public static func normalized(_ text: String) throws(SelfWikilinkError) -> String {
        var inner = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if inner.hasPrefix("[["), inner.hasSuffix("]]"), inner.count >= 4 {
            inner = inner.dropFirst(2).dropLast(2)
        }
        // Spaces only: a newline inside the brackets is part of the target,
        // and the target check below refuses it.
        let target = inner.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { throw .empty }
        let forbidden = syntaxCharacters.union(.newlines).union(.controlCharacters)
        guard !target.unicodeScalars.contains(where: forbidden.contains) else { throw .malformed }
        return "[[\(target)]]"
    }

    /// The page a hand-written value links to, as `[[target]]`, or `nil` when
    /// it names none. Tolerant where `normalized` is strict: an alias, heading
    /// or block reference is valid Obsidian syntax in a file the user edits,
    /// so it is dropped rather than refused, leaving the page that
    /// `FilenameResolver` and attribution match on.
    public static func target(ofConfigured text: String) -> String? {
        var inner = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if inner.hasPrefix("[["), inner.hasSuffix("]]"), inner.count >= 4 {
            inner = inner.dropFirst(2).dropLast(2)
        }
        if let suffix = inner.firstIndex(where: { $0 == "|" || $0 == "#" || $0 == "^" }) {
            inner = inner[..<suffix]
        }
        return try? normalized(String(inner))
    }

    /// A person's name made safe to wrap in `[[…]]`: link-syntax and control
    /// characters dropped, runs of whitespace collapsed to one space, and the
    /// ends trimmed. `nil` when nothing of the name remains.
    public static func fromName(_ name: String) -> String? {
        let dropped = syntaxCharacters.union(.controlCharacters).subtracting(.whitespacesAndNewlines)
        let kept = name.unicodeScalars
            .filter { !dropped.contains($0) }
            .map { CharacterSet.whitespacesAndNewlines.contains($0) ? " " : Character($0) }
        let collapsed = String(kept)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }
}
