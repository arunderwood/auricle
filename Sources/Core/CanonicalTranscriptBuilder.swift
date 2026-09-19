import Foundation

/// The one place a `CanonicalTranscript` is assembled from utterance text, so
/// the invariants every later stage relies on hold by construction rather than
/// by each producer's care:
///
/// - text is NFC and line breaks are LF, because a quote is later matched
///   against it byte for byte;
/// - no line has leading or trailing whitespace;
/// - each utterance is `<speakerLabel>: <text>`, utterances are joined with a
///   single LF, and there is no trailing newline;
/// - each utterance's `[start, end)` range is in UTF-8 bytes, covers its own
///   `<speakerLabel>: ` prefix, and excludes the LF that joins it to the next.
///
/// An utterance with no text left after canonicalization is dropped: an
/// `end` equal to `start` plus the prefix would name a speaker with nothing
/// to say.
public enum CanonicalTranscriptBuilder {
    public static func build(_ utterances: [(speakerLabel: String, text: String)]) -> CanonicalTranscript {
        var text = ""
        var offset = 0
        var built: [CanonicalTranscript.Utterance] = []
        for utterance in utterances {
            guard let body = canonicalText(utterance.text) else { continue }
            let line = "\(utterance.speakerLabel): \(body)"
            if !built.isEmpty {
                text += "\n"
                offset += 1
            }
            let byteCount = line.utf8.count
            built.append(CanonicalTranscript.Utterance(speakerLabel: utterance.speakerLabel, start: offset, end: offset + byteCount))
            text += line
            offset += byteCount
        }
        return CanonicalTranscript(text: text, utterances: built)
    }

    /// NFC, every line-break form turned into LF, each line trimmed, blank
    /// lines removed. `nil` when nothing is left.
    ///
    /// Blank lines go, not just edge ones: a blank line inside an utterance
    /// would put an empty line into the middle of a range that is otherwise
    /// one block of speech.
    static func canonicalText(_ raw: String) -> String? {
        let lines = raw.precomposedStringWithCanonicalMapping
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }
}
