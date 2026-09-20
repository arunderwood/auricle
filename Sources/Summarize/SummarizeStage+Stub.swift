import Core
import Foundation
import Orchestrator

extension SummarizeStage {
    /// `summary.json` through `CacheArtifactWriter`; a failed write is the
    /// stage's own `summary_write_failed`, never the writer's error, which
    /// carries a path.
    static func writeSummary(_ artifact: SummaryArtifact, for meetingID: MeetingID) throws {
        do {
            try CacheArtifactWriter.write(artifact, for: meetingID, named: summaryArtifactName, schemaVersion: summarySchemaVersion)
        } catch {
            throw SummarizeStageError.summaryWriteFailed
        }
    }

    /// Under `--publish-anyway` a summarizer failure still publishes. The stub
    /// is built by the stage, from what it already holds, because the run verb
    /// lives in another process and holds none of it. The stage completes into
    /// `persisting`, and the failure it stands in for is recorded on that row.
    ///
    /// A complete `summary.json` already on disk (a re-summarize of a published
    /// meeting) is never overwritten by a stub: the failure stands as
    /// `summarization_failed` and the good summary stays.
    static func completeWithStub(after error: Error, for meetingID: MeetingID, stub: SummaryArtifact) throws -> StageRunner.StageOutcome {
        if hasCompleteSummary(for: meetingID) {
            throw error
        }
        try writeSummary(stub, for: meetingID)
        return .completed(targetState: .persisting, metadataJSON: stubMetadataJSON(errorClass: failure(for: error).errorClass))
    }

    private static func hasCompleteSummary(for meetingID: MeetingID) -> Bool {
        guard
            let directory = try? CacheArtifactWriter.cacheDirectory(for: meetingID),
            let data = try? Data(contentsOf: directory.appendingPathComponent(summaryArtifactName)),
            let existing = try? JSONDecoder().decode(SummaryArtifact.self, from: data)
        else {
            return false
        }
        return !existing.needsSummary
    }

    /// Encoding two scalars cannot fail in practice, and `work` must not crash
    /// on the row that records it, so a failure degrades to `{}`.
    private static func stubMetadataJSON(errorClass: String) -> String {
        let object: [String: Any] = ["error_class": errorClass, "needs_summary": true]
        guard
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return json
    }
}
