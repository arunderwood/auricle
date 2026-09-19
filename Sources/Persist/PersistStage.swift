import Core
import Foundation
import Orchestrator
import State
import Telemetry

/// The `persist` stage entry point: composes `FrontmatterRenderer` (2.1) +
/// `FilenameResolver` (2.2) + `VaultWriter` (2.3) into the `summarizing` →
/// `published` transition, plus re-publish (`--reattribute`) semantics
/// (Decision 2.3/2.4). The whole body runs inside `StageRunner.run`'s `work`
/// closure — this type never writes `stage_events`/`meetings.state` itself.
public enum PersistStage {
    /// `frontmatter_schema_version` (Decision 2.2): required forever, never
    /// renamed. Fixed at `1` until a breaking frontmatter change ships.
    private static let frontmatterSchemaVersion = 1

    /// Same rationale as `VaultWriter.maxCollisionOrdinal`: same-day reruns
    /// this deep aren't realistic, but the loop must still fail fast rather
    /// than spin forever on a defect. Kept separate from
    /// `VaultWriter.maxCollisionOrdinal` — same-day-collision ordinals and
    /// rerun ordinals are different axes (Decision 2.4) that only happen to
    /// share a cap value.
    static let maxRerunOrdinal = 1000

    public enum PersistError: Error {
        case summaryArtifactUnreadable(path: String, underlying: Error)
        case summaryArtifactUndecodable(path: String, underlying: Error)
        case meetingNotFound(meetingID: MeetingID)
        case missingCaptureStartedAt(meetingID: MeetingID)
        /// `path` is the last rerun candidate tried (at `maxRerunOrdinal`).
        case rerunRetriesExhausted(path: String, maxOrdinal: Int)

        /// The stable snake_case string each case folds into the `.failed`
        /// outcome's `errorClass`, per the I/O matrix.
        var errorClass: String {
            switch self {
            case .summaryArtifactUnreadable: "summary_artifact_unreadable"
            case .summaryArtifactUndecodable: "summary_artifact_undecodable"
            case .meetingNotFound: "meeting_not_found"
            case .missingCaptureStartedAt: "missing_capture_started_at"
            case .rerunRetriesExhausted: "rerun_retries_exhausted"
            }
        }
    }

    /// Where and how to reach the vault for this run. Bundled into one value
    /// so the internal helpers below stay under SwiftLint's function
    /// parameter cap without reshaping `run(...)`'s own labeled parameter
    /// list, which is this story's specified public API surface.
    private struct VaultLocation {
        let vaultPath: URL
        let meetingsSubdir: String
    }

    /// The two ambient inputs the stage reads: the instant a re-run is
    /// published, and the zone every filename/frontmatter date is rendered
    /// in. Injectable so tests can pin both; production uses the system clock
    /// and the process's current zone.
    public struct TimeSource: Sendable {
        public let now: @Sendable () -> Date
        public let timeZone: TimeZone

        public init(
            now: @escaping @Sendable () -> Date = { Date() },
            timeZone: TimeZone = .current,
        ) {
            self.now = now
            self.timeZone = timeZone
        }
    }

    /// Everything `publish` resolves before it can render or write anything:
    /// the decoded cache artifact, the fetched `Meeting` row, and the local
    /// date/time both the renderer and the filename resolver need. Bundled
    /// for the same function-parameter-cap reason as `VaultLocation`.
    private struct ResolvedMeeting {
        let meetingID: MeetingID
        let artifact: SummaryArtifact
        let meeting: Meeting
        let localDate: String
        let localTime24h: String
    }

    /// Reads `summary.json` from `cacheDirectory`, fetches `meetingID`'s row,
    /// writes the rendered note (fresh publish or rerun, per `isRepublish`),
    /// updates `meetings.vault_note_path`, and returns through
    /// `stageRunner.run` so the `summarizing` → `published`/`persist_failed`
    /// transition and its `stage_events` rows are always the two-transaction
    /// pattern's own writes, never this stage's.
    public static func run(
        meetingID: MeetingID,
        isRepublish: Bool,
        cacheDirectory: URL,
        vaultPath: URL,
        meetingsSubdir: String,
        stateStore: StateStore,
        stageRunner: StageRunner,
        clock: TimeSource = TimeSource(),
    ) async throws -> StageRunner.StageOutcome {
        let vaultLocation = VaultLocation(vaultPath: vaultPath, meetingsSubdir: meetingsSubdir)
        return try await stageRunner.run(stage: .persist, meetingID: meetingID, activeState: .persisting) {
            do {
                return try await publish(
                    meetingID: meetingID,
                    isRepublish: isRepublish,
                    cacheDirectory: cacheDirectory,
                    vaultLocation: vaultLocation,
                    stateStore: stateStore,
                    clock: clock,
                )
            } catch {
                return .failed(
                    targetState: .persistFailed,
                    errorClass: errorClass(for: error),
                    errorMessage: String(describing: error),
                )
            }
        }
    }

    // MARK: - Publish

    private static func publish(
        meetingID: MeetingID,
        isRepublish: Bool,
        cacheDirectory: URL,
        vaultLocation: VaultLocation,
        stateStore: StateStore,
        clock: TimeSource,
    ) async throws -> StageRunner.StageOutcome {
        let artifact = try readSummaryArtifact(cacheDirectory: cacheDirectory)

        guard var meeting = try await stateStore.fetchMeeting(id: meetingID.rawValue) else {
            throw PersistError.meetingNotFound(meetingID: meetingID)
        }
        guard
            let captureStartedAtString = meeting.captureStartedAt,
            let captureStartedAt = ISO8601UTC.date(from: captureStartedAtString)
        else {
            throw PersistError.missingCaptureStartedAt(meetingID: meetingID)
        }

        // The one documented local-time exception (Decision 2.4): every
        // other timestamp in the system is UTC.
        let (localDate, localTime24h) = localDateAndTime(from: captureStartedAt, in: clock.timeZone)
        let resolved = ResolvedMeeting(
            meetingID: meetingID,
            artifact: artifact,
            meeting: meeting,
            localDate: localDate,
            localTime24h: localTime24h,
        )

        let writtenURL = try writeNote(
            resolved: resolved,
            isRepublish: isRepublish,
            vaultLocation: vaultLocation,
            clock: clock,
        )

        meeting.vaultNotePath = writtenURL.path
        try await stateStore.updateMeeting(meeting)

        return .completed(targetState: .published, metadataJSON: encodeMetadataJSON(vaultNotePath: writtenURL.path))
    }

    /// Picks the rerun path (Decision 2.3) or the standard fresh-publish path
    /// (Decision 2.4) and performs exactly one vault write. `isRepublish`
    /// alone never selects the rerun path — a nil or dangling
    /// `vaultNotePath` (never published, or the user deleted the original)
    /// always falls through to a standard publish, per Decision 2.3's
    /// documented fallback.
    private static func writeNote(
        resolved: ResolvedMeeting,
        isRepublish: Bool,
        vaultLocation: VaultLocation,
        clock: TimeSource,
    ) throws -> URL {
        if isRepublish,
           let existingPath = resolved.meeting.vaultNotePath,
           FileManager.default.fileExists(atPath: existingPath) {
            let originalURL = URL(fileURLWithPath: existingPath)
            let (rerunDate, _) = localDateAndTime(from: clock.now(), in: clock.timeZone)
            let rerunURL = try nextRerunURL(originalURL: originalURL, rerunDate: rerunDate)
            let markdown = FrontmatterRenderer.render(
                meeting: frontmatterMeeting(resolved, supersedes: originalURL.lastPathComponent),
            )
            try VaultWriter.writeExact(markdown, to: rerunURL)
            return rerunURL
        }

        let markdown = FrontmatterRenderer.render(meeting: frontmatterMeeting(resolved, supersedes: nil))
        let forFilename = MeetingForFilename(
            meetingID: resolved.meetingID,
            captureDate: resolved.localDate,
            captureTime24h: resolved.localTime24h,
            calendarEventTitle: resolved.artifact.calendarEventTitle,
            attendees: resolved.artifact.attendees,
            selfWikilink: resolved.artifact.selfWikilink,
        )
        return try VaultWriter.write(
            markdown,
            meeting: forFilename,
            vaultPath: vaultLocation.vaultPath,
            meetingsSubdir: vaultLocation.meetingsSubdir,
        )
    }

    private static func frontmatterMeeting(_ resolved: ResolvedMeeting, supersedes: String?) -> MeetingForFrontmatter {
        MeetingForFrontmatter(
            meetingID: resolved.meetingID,
            title: resolved.artifact.title,
            date: resolved.localDate,
            attendees: resolved.artifact.attendees,
            schemaVersion: frontmatterSchemaVersion,
            supersedes: supersedes,
            needsAttribution: resolved.artifact.needsAttribution,
            needsCalendarEnrichment: resolved.artifact.needsCalendarEnrichment,
            summary: resolved.artifact.summary,
            actionItems: resolved.artifact.actionItems.map { QuotedItem(text: $0.text, quote: $0.quote) },
            decisions: resolved.artifact.decisions.map { QuotedItem(text: $0.text, quote: $0.quote) },
            transcriptSegments: resolved.artifact.transcriptSegments.map { TranscriptSegment(speaker: $0.speaker, text: $0.text) },
            audioPath: resolved.meeting.audioCachePath,
            calendarEventID: resolved.meeting.calendarEventID,
            retentionPolicy: resolved.meeting.retentionPolicy,
        )
    }

    // MARK: - summary.json

    private static func readSummaryArtifact(cacheDirectory: URL) throws -> SummaryArtifact {
        let summaryURL = cacheDirectory.appendingPathComponent("summary.json")
        let data: Data
        do {
            data = try Data(contentsOf: summaryURL)
        } catch {
            throw PersistError.summaryArtifactUnreadable(path: summaryURL.path, underlying: error)
        }
        do {
            return try JSONDecoder().decode(SummaryArtifact.self, from: data)
        } catch {
            throw PersistError.summaryArtifactUndecodable(path: summaryURL.path, underlying: error)
        }
    }

    // MARK: - Rerun filename construction

    /// The `--rerun-<YYYY-MM-DD>[-N]` tail a previous re-run left on a note's
    /// stem. `[0-9]`, not `\d`: ICU's `\d` also matches non-ASCII digits.
    private static let rerunSuffixPattern = "--rerun-[0-9]{4}-[0-9]{2}-[0-9]{2}(-[0-9]+)?$"

    /// Builds `<base-stem>--rerun-<rerunDate>[-N].md` in the original's own
    /// directory (Decision 2.4's own text: this is a different axis than
    /// `FilenameResolver`'s single-hyphen ordinal, and belongs to the
    /// persist stage, not that resolver). Deterministic, existence-checked
    /// candidates — never `FilenameResolver.resolve`, which has no rerun
    /// suffix shape to produce.
    ///
    /// `originalURL` is whatever `meetings.vault_note_path` holds, which is
    /// the previous re-run once one exists. The candidate is built from the
    /// stem with that re-run's suffix stripped, so every re-run of a meeting
    /// is a sibling of the first note (`<base>--rerun-D[-N]`) rather than a
    /// suffix stacked on a suffix, and the same-day ordinal stays reachable.
    private static func nextRerunURL(originalURL: URL, rerunDate: String) throws -> URL {
        let directory = originalURL.deletingLastPathComponent()
        var stem = originalURL.deletingPathExtension().lastPathComponent
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
                return candidateURL
            }
            let nextOrdinal = (ordinal ?? 1) + 1
            guard nextOrdinal <= maxRerunOrdinal else {
                throw PersistError.rerunRetriesExhausted(path: candidateURL.path, maxOrdinal: maxRerunOrdinal)
            }
            ordinal = nextOrdinal
        }
    }

    // MARK: - Local date/time (Decision 2.4's local-time exception)

    /// Formats `date` as `("YYYY-MM-DD", "HHMM")` in `timeZone` —
    /// numeric `DateComponents` extraction rather than `DateFormatter`, so
    /// the result can't be perturbed by the process's `Locale` (only its
    /// `TimeZone`, which is exactly the one axis Decision 2.4 means to vary
    /// on).
    private static func localDateAndTime(from date: Date, in timeZone: TimeZone) -> (date: String, time24h: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let dateString = String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
        let timeString = String(format: "%02d%02d", components.hour ?? 0, components.minute ?? 0)
        return (dateString, timeString)
    }

    // MARK: - metadata_json

    /// Encodes `PersistMeta` directly — not wrapped in `StageMetadata.persist`,
    /// whose enum-keyed encoding nests the payload under a `"persist"` key,
    /// a different shape than Decision 4.5 specifies for this row.
    private static func encodeMetadataJSON(vaultNotePath: String) -> String {
        let meta = PersistMeta(vaultNotePath: vaultNotePath, frontmatterSchemaVersion: frontmatterSchemaVersion)
        // `PersistMeta` is two plain, always-encodable scalars (String, Int)
        // with no custom encoding strategy in play, so this can't actually
        // fail in practice. Still: a stage that promises "nothing propagates
        // uncaught past `work`" must not crash the whole process on the one
        // path that least needs an escape hatch — fall back to a minimal
        // valid JSON literal rather than `fatalError`.
        guard
            let data = try? JSONEncoder().encode(meta),
            let json = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return json
    }

    // MARK: - error_class mapping

    /// Every error `publish` can throw, folded to the I/O matrix's stable
    /// snake_case `errorClass`. `VaultWriter.WriteError` and
    /// `AtomicWriter.WriteError` both fold to `"vault_write_failed"` — the
    /// matrix doesn't distinguish which of the two layers rejected the
    /// write, only that the write itself failed. The default case is
    /// defensive only: no I/O-matrix row models a `StateStore` call itself
    /// throwing (a GRDB-level failure), but `work` must still catch and
    /// classify it rather than let it propagate uncaught.
    private static func errorClass(for error: Error) -> String {
        switch error {
        case let persistError as PersistError:
            persistError.errorClass
        case is VaultWriter.WriteError, is AtomicWriter.WriteError:
            "vault_write_failed"
        default:
            "persist_unexpected_error"
        }
    }
}
