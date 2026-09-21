import AVFoundation
import Core
import Foundation
import Orchestrator
import State
import Telemetry
import TranscriberInterface

/// The `transcribe` stage entry point: reads `audio.wav` from the meeting's
/// cache directory, runs the injected `TranscriberStrategy`, and writes the
/// `transcript.json` every later stage reads. The whole body runs inside
/// `StageRunner.run`'s `work` closure, so this type never writes
/// `stage_events` or `meetings.state` itself, and every failure is folded
/// into a `transcription_failed` outcome rather than thrown.
///
/// The stage depends on the `TranscriberStrategy` protocol only. It knows no
/// concrete transcriber, no diarizer, and nothing about how a transcript was
/// produced beyond the `CanonicalTranscript` it gets back.
public enum TranscribeStage {
    /// What a diarization step is handed once the transcript is written.
    public struct DiarizationInput: Sendable {
        public let meetingID: MeetingID
        public let transcript: CanonicalTranscript
        public let utteranceTimings: [UtteranceTiming]
        public let audio: URL
    }

    /// The step that diarizes the meeting inside this stage's own transaction,
    /// injected so this module names no diarizer. It throws only
    /// `ClassifiedStageError`s, whose class and message become the failure
    /// row's.
    public typealias DiarizationStep = @Sendable (DiarizationInput) async throws -> DiarizeMeta

    private static let audioArtifactName = "audio.wav"
    private static let transcriptArtifactName = "transcript.json"
    private static let transcriptSchemaVersion = 1
    private static let timingsArtifactName = "utterance_timings.json"
    private static let timingsSchemaVersion = 1

    /// Completes into `transcribing`: no state sits between transcribe,
    /// diarize and review, so the state the stage entered is the state it
    /// leaves the meeting in.
    ///
    /// Throws `StateStoreError.meetingNotFound` when `meetingID` has no row,
    /// before anything is recorded: `StageRunner.run`'s first transaction
    /// cannot start for a meeting that does not exist, and where foreign
    /// keys are enforced it would fail with a `DatabaseError` instead of a
    /// typed error the caller can act on.
    public static func run(
        meetingID: MeetingID,
        stateStore: StateStore,
        stageRunner: StageRunner,
        transcriber: any TranscriberStrategy,
        config: TranscriberConfig = TranscriberConfig(),
        diarize: DiarizationStep? = nil,
    ) async throws -> StageRunner.StageOutcome {
        guard try await stateStore.fetchMeeting(id: meetingID.rawValue) != nil else {
            throw StateStoreError.meetingNotFound(id: meetingID.rawValue)
        }
        return try await stageRunner.run(stage: .transcribe, meetingID: meetingID, activeState: .transcribing) {
            do {
                return try await transcribe(meetingID: meetingID, transcriber: transcriber, config: config, diarize: diarize)
            } catch {
                let classified = failure(for: error)
                return .failed(
                    targetState: .transcriptionFailed,
                    errorClass: classified.errorClass,
                    errorMessage: classified.message,
                )
            }
        }
    }

    /// `WorkerExitCode.success` on success, `retryable` for a failure a fresh
    /// process might not repeat, and `stateError` (Decision 1.5) for every
    /// other one.
    public static func exitCode(for outcome: StageRunner.StageOutcome) -> Int32 {
        switch outcome {
        case .completed:
            WorkerExitCode.success
        case let .failed(_, errorClass, _, _):
            TranscribeStageError.retryableErrorClasses.contains(errorClass) ? WorkerExitCode.retryable : WorkerExitCode.stateError
        }
    }

    // MARK: - Stage body

    /// The audio is opened before the transcriber is called, so a file that
    /// is missing or is not audio fails without paying for a model load.
    private static func transcribe(
        meetingID: MeetingID,
        transcriber: any TranscriberStrategy,
        config: TranscriberConfig,
        diarize: DiarizationStep?,
    ) async throws -> StageRunner.StageOutcome {
        let audio = try audioURL(for: meetingID)
        let durationSeconds = try audioDurationSeconds(of: audio)

        let timed: TimedTranscript = if let resumed = resumedTranscript(for: meetingID) {
            resumed
        } else {
            try await transcribeAndWrite(meetingID: meetingID, audio: audio, transcriber: transcriber, config: config)
        }
        let transcript = timed.transcript

        let diarizeMeta = try await diarize?(DiarizationInput(
            meetingID: meetingID,
            transcript: transcript,
            utteranceTimings: timed.utteranceTimings,
            audio: audio,
        ))

        return .completed(
            targetState: .transcribing,
            metadataJSON: encodeMetadataJSON(config: config, audioDurationSeconds: durationSeconds, transcript: transcript, diarize: diarizeMeta),
        )
    }

    /// Timings are written before the transcript, and the transcript is what
    /// makes the pair usable: a crash between the two writes leaves timings
    /// with no transcript, which is not resumed.
    private static func transcribeAndWrite(
        meetingID: MeetingID,
        audio: URL,
        transcriber: any TranscriberStrategy,
        config: TranscriberConfig,
    ) async throws -> TimedTranscript {
        let timed: TimedTranscript
        do {
            timed = try await transcriber.transcribeTimed(audio: audio, config: config)
        } catch let error as TranscriberError {
            throw TranscribeStageError(error)
        }

        do {
            try CacheArtifactWriter.write(
                TimingsArtifact(timings: timed.utteranceTimings),
                for: meetingID,
                named: timingsArtifactName,
                schemaVersion: timingsSchemaVersion,
            )
            try CacheArtifactWriter.write(timed.transcript, for: meetingID, named: transcriptArtifactName, schemaVersion: transcriptSchemaVersion)
        } catch {
            throw TranscribeStageError.transcriptWriteFailed
        }
        return timed
    }

    /// The transcript is immutable once written, so a retry after a later
    /// step failed reuses it instead of paying for transcription again. It is
    /// reused only when the timings are readable and cover exactly its
    /// utterances: anything else is transcribed afresh.
    private static func resumedTranscript(for meetingID: MeetingID) -> TimedTranscript? {
        guard
            let directory = try? CacheArtifactWriter.cacheDirectory(for: meetingID),
            let transcriptData = try? Data(contentsOf: directory.appendingPathComponent(transcriptArtifactName)),
            let timingsData = try? Data(contentsOf: directory.appendingPathComponent(timingsArtifactName)),
            let transcript = try? JSONDecoder().decode(CanonicalTranscript.self, from: transcriptData),
            let artifact = try? JSONDecoder().decode(TimingsArtifact.self, from: timingsData)
        else {
            return nil
        }
        let timings = artifact.timings
        guard timings.count == transcript.utteranceCount, timings.indices.allSatisfy({ timings[$0].index == $0 }) else {
            return nil
        }
        return TimedTranscript(transcript: transcript, utteranceTimings: timings)
    }

    /// A cache root that cannot be resolved means the audio cannot be found
    /// either, so it is reported as the missing audio it causes.
    private static func audioURL(for meetingID: MeetingID) throws -> URL {
        let url: URL
        do {
            url = try CacheArtifactWriter.cacheDirectory(for: meetingID).appendingPathComponent(audioArtifactName)
        } catch {
            throw TranscribeStageError.audioMissing
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TranscribeStageError.audioMissing
        }
        return url
    }

    private static func audioDurationSeconds(of url: URL) throws -> Int {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw TranscribeStageError.audioUnreadable
        }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else {
            throw TranscribeStageError.audioUnreadable
        }
        return Int((Double(file.length) / sampleRate).rounded())
    }

    // MARK: - metadata_json

    /// Encodes `TranscribeMeta` directly, not wrapped in
    /// `StageMetadata.transcribe`, whose enum-keyed encoding would nest the
    /// payload under a `"transcribe"` key — a different shape than Decision
    /// 4.5 specifies for this row. Encoding these scalar fields cannot fail
    /// in practice, and `work` must not crash the process on the one path
    /// that least needs an escape hatch, so a failure degrades to `{}`.
    private static func encodeMetadataJSON(
        config: TranscriberConfig,
        audioDurationSeconds: Int,
        transcript: CanonicalTranscript,
        diarize: DiarizeMeta?,
    ) -> String {
        let meta = TranscribeMeta(
            modelID: config.modelID,
            audioDurationSeconds: audioDurationSeconds,
            transcriptChars: transcript.text.count,
            diarize: diarize,
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard
            let data = try? encoder.encode(meta),
            let json = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return json
    }

    // MARK: - Failure classification

    /// Only a case name, a type name or a fixed sentence is ever recorded,
    /// never an error's own message: a foreign error can embed a path or
    /// transcript text, and `error_message` is persisted in `stage_events`.
    private static func failure(for error: Error) -> (errorClass: String, message: String) {
        if let classified = error as? any ClassifiedStageError {
            return (classified.errorClass, classified.errorMessage)
        }
        return ("transcribe_unexpected_error", String(reflecting: type(of: error)))
    }
}
