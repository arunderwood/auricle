import Core
import Foundation

/// Why a `--speakers` value was refused. `entry` is the offending piece of
/// the caller's own command line, which is safe to echo back.
public enum SpeakersFlagError: Error, Equatable, Sendable {
    case noEntries
    case malformedEntry(String)
    case emptyName(String)
    case duplicateKey(String)
    case duplicateName(String)
    case unknownSpeaker(String)

    public var message: String {
        switch self {
        case .noEntries: "--speakers has no entries."
        case let .malformedEntry(entry): "--speakers entry \"\(entry)\" is not <number>=<name>."
        case let .emptyName(entry): "--speakers entry \"\(entry)\" has no name."
        case let .duplicateKey(entry): "--speakers names speaker \(entry) more than once."
        case let .duplicateName(entry): "--speakers gives the name \"\(entry)\" to more than one speaker."
        case let .unknownSpeaker(entry): "--speakers entry \"\(entry)\" is not a speaker in this meeting."
        }
    }
}

/// Parses `--speakers "1=Ben,2=Jordan Whitfield"` against the speakers a
/// meeting's `diarization.json` has.
public enum SpeakersFlagParser {
    /// The full `speakers` map: every label in `labels`, the mapped ones as
    /// `[[Name]]` and the rest as their own `Speaker_N` placeholder. Nothing is
    /// returned for a value with any bad entry.
    public static func parse(_ raw: String, labels: [String], glossary: Glossary = Glossary()) throws(SpeakersFlagError) -> [String: String] {
        let entries = raw.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard !(entries.count == 1 && entries[0].isEmpty) else { throw .noEntries }

        var mapping: [String: String] = [:]
        var seenNames = Set<String>()
        for entry in entries {
            guard let separator = entry.firstIndex(of: "=") else { throw .malformedEntry(entry) }
            let key = entry[..<separator].trimmingCharacters(in: .whitespaces)
            let name = SpeakerNaming.bareName(String(entry[entry.index(after: separator)...]))
            guard !key.isEmpty, key.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw .malformedEntry(entry) }
            guard !name.isEmpty else { throw .emptyName(entry) }
            guard !SpeakerNaming.isPlaceholder(name) else { throw .malformedEntry(entry) }
            let label = "Speaker_\(key)"
            guard labels.contains(label) else { throw .unknownSpeaker(entry) }
            guard mapping[label] == nil else { throw .duplicateKey(key) }
            let canonical = SpeakerNaming.canonicalName(name, glossary: glossary)
            guard seenNames.insert(canonical.lowercased()).inserted else { throw .duplicateName(canonical) }
            mapping[label] = SpeakerNaming.value(forName: name, label: label, glossary: glossary)
        }
        for label in labels where mapping[label] == nil {
            mapping[label] = label
        }
        return mapping
    }
}
