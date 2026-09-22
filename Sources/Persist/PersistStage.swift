import Core
import Foundation
import Orchestrator
import State
import Telemetry

/// The `persist` stage entry point: composes `FrontmatterRenderer` (2.1) +
/// `FilenameResolver` (2.2) + `VaultWriter` (2.3) into the `persisting` →
/// `published` transition, plus re-publish (`--reattribute`) semantics
/// (Decision 2.3/2.4). The whole body runs inside `StageRunner.run`'s `work`
/// closure — this type never writes `stage_events`/`meetings.state` itself.
public enum PersistStage {
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
    /// publishes the rendered note, updates `meetings.vault_note_path`, and
    /// returns through `stageRunner.run` so the `persisting` →
    /// `published`/`published_partial`/`persist_failed` transition and its `stage_events` rows are
    /// always the two-transaction pattern's own writes, never this stage's.
    ///
    /// The stage is never told which path it is on. A run is a re-publish
    /// exactly when the meeting already has a note: the file `vaultNotePath`
    /// names or, when that file is gone, the note in the configured meetings
    /// folder whose `auricle.meeting_id` is this meeting's. A meeting with no
    /// recorded `vaultNotePath`, or with no note found, is a fresh publish.
    /// Output identical to what a vault file already holds is reused rather
    /// than written again, so re-running the stage never leaves a duplicate
    /// note behind.
    public static func run(
        meetingID: MeetingID,
        cacheDirectory: URL,
        vaultPath: URL,
        meetingsSubdir: String,
        stateStore: StateStore,
        stageRunner: StageRunner,
        clock: TimeSource = TimeSource(),
        expectedState: PipelineState? = nil,
    ) async throws -> StageRunner.StageOutcome {
        let vaultLocation = VaultLocation(vaultPath: vaultPath, meetingsSubdir: meetingsSubdir)
        return try await stageRunner.run(stage: .persist, meetingID: meetingID, activeState: .persisting, expectedState: expectedState) {
            do {
                return try await publish(
                    meetingID: meetingID,
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
        cacheDirectory: URL,
        vaultLocation: VaultLocation,
        stateStore: StateStore,
        clock: TimeSource,
    ) async throws -> StageRunner.StageOutcome {
        let artifact = try readSummaryArtifact(cacheDirectory: cacheDirectory)

        guard let meeting = try await stateStore.fetchMeeting(id: meetingID.rawValue) else {
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
            vaultLocation: vaultLocation,
            clock: clock,
        )

        try await stateStore.setVaultNotePath(meetingID: meetingID.rawValue, path: writtenURL.path)

        let target: PipelineState = artifact.needsSummary ? .publishedPartial : .published
        return .completed(targetState: target, metadataJSON: encodeMetadataJSON(vaultNotePath: writtenURL.path))
    }

    /// Picks the re-publish path (Decision 2.3) or the fresh-publish path
    /// (Decision 2.4) and performs at most one vault write. A meeting with no
    /// note on disk (never published, or the user deleted it) is a fresh
    /// publish, per Decision 2.3's documented fallback.
    private static func writeNote(
        resolved: ResolvedMeeting,
        vaultLocation: VaultLocation,
        clock: TimeSource,
    ) throws -> URL {
        if let predecessorURL = try findPredecessor(resolved: resolved, vaultLocation: vaultLocation) {
            return try republish(resolved: resolved, predecessorURL: predecessorURL, vaultLocation: vaultLocation, clock: clock)
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

    /// The meeting's existing note, if it has one. The file `vaultNotePath`
    /// names wins wherever it sits, including outside the configured folder.
    /// A recorded path whose file is gone (the user renamed or moved the note)
    /// sends the search to the configured meetings folder, by `meeting_id`.
    ///
    /// A meeting with no recorded path has never been published, so it has no
    /// predecessor and nothing is scanned: the scan costs a read per file in
    /// the folder, and a first publish is on the stage's latency budget. A
    /// write whose path was never recorded is found by `VaultWriter.write`,
    /// which reuses the file that already holds the bytes.
    ///
    /// Only the search needs the folder, so a stored note is not checked
    /// against the configuration until a re-run has to be written next to it.
    private static func findPredecessor(resolved: ResolvedMeeting, vaultLocation: VaultLocation) throws -> URL? {
        guard let storedPath = resolved.meeting.vaultNotePath else {
            return nil
        }
        if FileManager.default.fileExists(atPath: storedPath) {
            return URL(fileURLWithPath: storedPath)
        }
        let meetingsDirectory = try VaultWriter.resolveMeetingsDirectory(
            vaultPath: vaultLocation.vaultPath,
            meetingsSubdir: vaultLocation.meetingsSubdir,
        )
        return PredecessorNoteFinder.find(meetingID: resolved.meetingID, in: meetingsDirectory)
    }

    /// The predecessor is the meeting's current published note, so nothing is
    /// written when it already holds what this run would render. Otherwise the
    /// new rendering goes to a `--rerun-` sibling that supersedes it, and the
    /// predecessor is never opened for writing: it may carry the user's edits.
    /// The re-run is written into the configured meetings folder, which may
    /// not be the folder the predecessor is in.
    private static func republish(
        resolved: ResolvedMeeting,
        predecessorURL: URL,
        vaultLocation: VaultLocation,
        clock: TimeSource,
    ) throws -> URL {
        // A predecessor that is itself a re-run carries the `supersedes` its
        // own publish rendered. Comparing against a rendering without it would
        // never match, and every unchanged run would then write another re-run.
        let predecessorSupersedes = supersedesValue(ofNoteAt: predecessorURL)
        let unchanged = FrontmatterRenderer.render(meeting: frontmatterMeeting(resolved, supersedes: predecessorSupersedes))
        if VaultWriter.fileHasContents(unchanged, at: predecessorURL) {
            return predecessorURL
        }

        let meetingsDirectory = try VaultWriter.resolveMeetingsDirectory(
            vaultPath: vaultLocation.vaultPath,
            meetingsSubdir: vaultLocation.meetingsSubdir,
        )
        let (rerunDate, _) = localDateAndTime(from: clock.now(), in: clock.timeZone)
        let markdown = FrontmatterRenderer.render(
            meeting: frontmatterMeeting(resolved, supersedes: predecessorURL.lastPathComponent),
        )
        let target = try nextRerunTarget(
            predecessorURL: predecessorURL,
            in: meetingsDirectory,
            rerunDate: rerunDate,
            markdown: markdown,
        )
        if !target.alreadyHoldsMarkdown {
            try VaultWriter.writeExact(markdown, to: target.url)
        }
        return target.url
    }

    /// `nil` for a note that supersedes nothing and for one whose frontmatter
    /// cannot be read (hand-edited beyond parsing): both compare as "changed"
    /// unless the bytes match a rendering without `supersedes`.
    private static func supersedesValue(ofNoteAt url: URL) -> String? {
        guard
            let data = try? Data(contentsOf: url),
            let contents = String(data: data, encoding: .utf8),
            let frontmatter = try? FrontmatterReader.read(noteContents: contents)
        else {
            return nil
        }
        return frontmatter.supersedes
    }

    private static func frontmatterMeeting(_ resolved: ResolvedMeeting, supersedes: String?) -> MeetingForFrontmatter {
        SummaryArtifactFrontmatter.meeting(
            resolved.artifact,
            meetingID: resolved.meetingID,
            date: resolved.localDate,
            supersedes: supersedes,
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
        let meta = PersistMeta(vaultNotePath: vaultNotePath, frontmatterSchemaVersion: FrontmatterSchema.current)
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
