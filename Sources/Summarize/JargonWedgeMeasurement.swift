import Core
import Foundation

/// The AI-correction wedge measurement (AR-AI-9): the share of meetings in a
/// rolling window that show at least one applied jargon correction. It needs no
/// telemetry column of its own, because everything it reads is already in each
/// meeting's cache directory: `summary.json`, `transcript.json` and the scoped
/// `glossary.json`.
///
/// The report holds counts only. Meeting text is read to decide, never kept.
public enum JargonWedgeMeasurement {
    public static let windowDays = 30
    /// The share of meetings with a correction the wedge has to reach.
    public static let criterion = 0.4

    public struct Report: Sendable, Equatable {
        public let windowDays: Int
        /// In-window meetings with all three artifacts readable.
        public let eligibleMeetings: Int
        public let meetingsWithCorrection: Int
        /// In-window meetings where an artifact is missing or unreadable. They
        /// are left out of the rate rather than counted as no correction,
        /// because a meeting nobody could check says nothing either way.
        public let missingArtifactMeetings: Int
        /// `nil` when no meeting was eligible.
        public let rate: Double?
        public let meetsCriterion: Bool

        public init(
            windowDays: Int,
            eligibleMeetings: Int,
            meetingsWithCorrection: Int,
            missingArtifactMeetings: Int,
            rate: Double?,
            meetsCriterion: Bool,
        ) {
            self.windowDays = windowDays
            self.eligibleMeetings = eligibleMeetings
            self.meetingsWithCorrection = meetingsWithCorrection
            self.missingArtifactMeetings = missingArtifactMeetings
            self.rate = rate
            self.meetsCriterion = meetsCriterion
        }
    }

    private static let summaryName = "summary.json"
    private static let transcriptName = "transcript.json"
    private static let glossaryName = "glossary.json"

    /// A meeting is in the window when its `summary.json` was last modified
    /// inside it: that file is written once, when the summary is made. A
    /// directory with no `summary.json` never finished summarizing and is not
    /// a meeting for this purpose.
    public static func measure(cacheRoot: URL, now: Date = Date()) -> Report {
        let windowStart = now.addingTimeInterval(-Double(windowDays) * 86400)
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: cacheRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
        )) ?? []

        var eligible = 0
        var withCorrection = 0
        var missing = 0
        for directory in directories.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let summaryURL = directory.appendingPathComponent(summaryName)
            guard
                let modified = try? summaryURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                modified >= windowStart, modified <= now
            else { continue }

            guard let artifacts = readArtifacts(in: directory) else {
                missing += 1
                continue
            }
            eligible += 1
            if hasCorrection(artifacts) {
                withCorrection += 1
            }
        }

        let rate = eligible > 0 ? Double(withCorrection) / Double(eligible) : nil
        return Report(
            windowDays: windowDays,
            eligibleMeetings: eligible,
            meetingsWithCorrection: withCorrection,
            missingArtifactMeetings: missing,
            rate: rate,
            meetsCriterion: rate.map { $0 >= criterion } ?? false,
        )
    }

    private struct Artifacts {
        let summary: SummaryArtifact
        let transcript: CanonicalTranscript
        let glossary: Glossary
    }

    /// `nil` when any of the three is absent or does not decode.
    private static func readArtifacts(in directory: URL) -> Artifacts? {
        let decoder = JSONDecoder()
        guard
            let summaryData = try? Data(contentsOf: directory.appendingPathComponent(summaryName)),
            let summary = try? decoder.decode(SummaryArtifact.self, from: summaryData),
            let transcriptData = try? Data(contentsOf: directory.appendingPathComponent(transcriptName)),
            let transcript = try? decoder.decode(CanonicalTranscript.self, from: transcriptData),
            let glossaryData = try? Data(contentsOf: directory.appendingPathComponent(glossaryName)),
            let glossary = try? decoder.decode(Glossary.self, from: glossaryData)
        else {
            return nil
        }
        return Artifacts(summary: summary, transcript: transcript, glossary: glossary)
    }

    /// The summary, the action items and the decisions are the model's own
    /// wording, so a corrected term can surface in any of them.
    private static func hasCorrection(_ artifacts: Artifacts) -> Bool {
        let text = ([artifacts.summary.summary] + artifacts.summary.actionItems.map(\.text) + artifacts.summary.decisions.map(\.text))
            .joined(separator: "\n")
        return !GlossaryJargonCorrector.corrections(
            summaryText: text,
            transcriptText: artifacts.transcript.text,
            glossary: artifacts.glossary,
        ).isEmpty
    }
}
