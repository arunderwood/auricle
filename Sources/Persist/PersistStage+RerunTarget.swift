import Foundation

extension PersistStage {
    /// The `--rerun-<YYYY-MM-DD>[-N]` tail a previous re-run left on a note's
    /// stem. `[0-9]`, not `\d`: ICU's `\d` also matches non-ASCII digits.
    private static let rerunSuffixPattern = "--rerun-[0-9]{4}-[0-9]{2}-[0-9]{2}(-[0-9]+)?$"

    /// Where a re-run's markdown goes: `alreadyHoldsMarkdown` is set when
    /// `url` exists with exactly those bytes, so no write is needed.
    struct RerunTarget {
        let url: URL
        let alreadyHoldsMarkdown: Bool
    }

    /// Finds `<base-stem>--rerun-<rerunDate>[-N].md` in `directory`, the
    /// configured meetings folder (Decision 2.4's own text: this is a
    /// different axis than `FilenameResolver`'s single-hyphen ordinal, and
    /// belongs to the persist stage, not that resolver). Deterministic,
    /// existence-checked candidates — never `FilenameResolver.resolve`, which
    /// has no rerun suffix shape to produce.
    ///
    /// A candidate that exists with exactly `markdown` is this meeting's own
    /// earlier write, left unrecorded by a failure after the write, and is
    /// reused. A candidate with other bytes belongs to a different re-run and
    /// is skipped. The date is the run's own, so a retry on a later day does
    /// not find an earlier day's orphaned re-run and writes a new one.
    ///
    /// `predecessorURL` is the meeting's current note, which is the previous
    /// re-run once one exists. The candidate is built from the stem with that
    /// re-run's suffix stripped, so every re-run of a meeting is a sibling of
    /// the first note (`<base>--rerun-D[-N]`) rather than a suffix stacked on
    /// a suffix, and the same-day ordinal stays reachable.
    static func nextRerunTarget(
        predecessorURL: URL,
        in directory: URL,
        rerunDate: String,
        markdown: String,
    ) throws -> RerunTarget {
        var stem = predecessorURL.deletingPathExtension().lastPathComponent
        if let suffixRange = stem.range(of: rerunSuffixPattern, options: .regularExpression) {
            stem.removeSubrange(suffixRange)
        }

        var ordinal: Int?
        while true {
            let suffix = if let ordinal, ordinal >= 2 {
                "-\(ordinal)"
            } else {
                ""
            }
            let candidateURL = directory.appendingPathComponent("\(stem)--rerun-\(rerunDate)\(suffix).md")
            guard FileManager.default.fileExists(atPath: candidateURL.path) else {
                return RerunTarget(url: candidateURL, alreadyHoldsMarkdown: false)
            }
            if VaultWriter.fileHasContents(markdown, at: candidateURL) {
                return RerunTarget(url: candidateURL, alreadyHoldsMarkdown: true)
            }
            let nextOrdinal = (ordinal ?? 1) + 1
            guard nextOrdinal <= maxRerunOrdinal else {
                throw PersistError.rerunRetriesExhausted(path: candidateURL.path, maxOrdinal: maxRerunOrdinal)
            }
            ordinal = nextOrdinal
        }
    }
}
