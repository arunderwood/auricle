import Core
import Foundation

/// How a typed name becomes a `speakers` value.
enum SpeakerNaming {
    /// The placeholder label for `Speaker_<digits>`.
    static func isPlaceholder(_ value: String) -> Bool {
        guard value.hasPrefix("Speaker_") else { return false }
        let digits = value.dropFirst("Speaker_".count)
        return !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// The bare name: brackets stripped and whitespace trimmed.
    static func bareName(_ value: String) -> String {
        value
            .replacingOccurrences(of: "[[", with: "")
            .replacingOccurrences(of: "]]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The glossary's spelling when `name` matches a person case-insensitively,
    /// otherwise `name` as typed. No vault file is created for an unknown name.
    static func canonicalName(_ name: String, glossary: Glossary) -> String {
        let folded = name.lowercased()
        return glossary.people.first { $0.lowercased() == folded } ?? name
    }

    /// `[[Name]]`, or `label` itself when `name` is empty or a `Speaker_N`
    /// literal.
    static func value(forName name: String, label: String, glossary: Glossary) -> String {
        let bare = bareName(name)
        if bare.isEmpty || isPlaceholder(bare) {
            return label
        }
        return "[[\(canonicalName(bare, glossary: glossary))]]"
    }
}
