import Core
import DiarizerInterface
import Foundation
import Telemetry

/// The diarization step: runs the injected `DiarizerStrategy`, writes the
/// immutable `diarization.json`, and cuts the per-speaker snippets the
/// attribution sheet plays.
///
/// Rewriting `diarization.json` removes the artifacts that describe the old
/// one (`DiarizationDependents`) first, so a crash between the two leaves
/// nothing stale behind.
///
/// It is a step, not a stage of its own. It records no `stage_events` row and
/// touches no state: `PipelineStage` has no `diarize` case, and the transcribe
/// stage that runs it in the same subprocess records the `DiarizeMeta` this
/// returns inside its own `completed` row.
///
/// It depends on the `DiarizerStrategy` protocol only, and on no concrete
/// engine and no transcribe code.
public enum DiarizeStage {
    private static let artifactName = "diarization.json"
    private static let snippetsDirectoryName = "snippets"
    private static let schemaVersion = 1

    /// Every error thrown is a `ClassifiedStageError` carrying a stable class
    /// and a message that is safe to persist; nothing else escapes.
    public static func run(
        meetingID: MeetingID,
        transcript: CanonicalTranscript,
        utteranceTimings: [UtteranceTiming],
        audio: URL,
        diarizer: any DiarizerStrategy,
        config: DiarizerConfig,
    ) async throws -> DiarizeMeta {
        let artifact: DiarizationArtifact
        do {
            artifact = try await diarizer.diarize(transcript: transcript, utteranceTimings: utteranceTimings, audio: audio, config: config)
        } catch let error as DiarizerError {
            throw DiarizeStageError(error)
        } catch {
            throw DiarizeUnexpectedError(typeName: String(reflecting: type(of: error)))
        }

        let directory: URL
        do {
            directory = try CacheArtifactWriter.cacheDirectory(for: meetingID)
            try DiarizationDependents.remove(in: directory)
            try CacheArtifactWriter.write(artifact, for: meetingID, named: artifactName, schemaVersion: schemaVersion)
        } catch {
            throw DiarizeStageError.artifactWriteFailed
        }

        let snippetCount: Int
        do {
            snippetCount = try SnippetExtractor.extract(
                artifact: artifact,
                audio: audio,
                directory: directory.appendingPathComponent(snippetsDirectoryName, isDirectory: true),
                durationSeconds: config.snippetDurationSeconds,
            )
        } catch {
            throw DiarizeStageError.snippetWriteFailed
        }

        return DiarizeMeta(
            modelID: config.modelID,
            segmentCount: artifact.segments.count,
            speakerCount: artifact.speakerLabels.count,
            snippetCount: snippetCount,
        )
    }
}
