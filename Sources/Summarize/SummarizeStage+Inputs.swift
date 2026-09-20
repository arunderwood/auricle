import Core
import Foundation

extension SummarizeStage {
    struct Inputs {
        let transcript: CanonicalTranscript
        let speakers: [String: String]?
        let captureStartedAt: Date
        let transcriptBytes: [UInt8]
        let segments: [TranscriptSegmentArtifact]
    }

    /// Reads and validates every input the stage has, in the order that fails
    /// cheapest first.
    static func readInputs(for meetingID: MeetingID, captureStartedAt: String?) throws -> Inputs {
        let cacheDirectory = try resolveCacheDirectory(for: meetingID)
        let transcript = try readTranscript(in: cacheDirectory)
        let speakers = try AttributionSpeakers.read(in: cacheDirectory)
        let captureStartedAtDate = try parseCaptureStartedAt(captureStartedAt)
        let transcriptBytes = Array(transcript.text.utf8)
        let segments = try SummaryArtifactMapper.transcriptSegments(
            of: transcript,
            transcriptBytes: transcriptBytes,
            speakers: speakers,
        )
        return Inputs(
            transcript: transcript,
            speakers: speakers,
            captureStartedAt: captureStartedAtDate,
            transcriptBytes: transcriptBytes,
            segments: segments,
        )
    }

    /// Decoded exactly once: the same `CanonicalTranscript` value is what the
    /// summarizer is given and what every quote and segment is sliced from,
    /// so the byte offsets a pointer carries mean the same thing at both ends.
    static func readTranscript(in cacheDirectory: URL) throws -> CanonicalTranscript {
        let data: Data
        do {
            data = try Data(contentsOf: cacheDirectory.appendingPathComponent(transcriptArtifactName))
        } catch {
            throw SummarizeStageError.transcriptMissing
        }
        do {
            return try JSONDecoder().decode(CanonicalTranscript.self, from: data)
        } catch {
            throw SummarizeStageError.transcriptUndecodable
        }
    }

    /// A cache root that cannot be resolved means the transcript cannot be
    /// found either, so it is reported as the missing transcript it causes.
    static func resolveCacheDirectory(for meetingID: MeetingID) throws -> URL {
        do {
            return try CacheArtifactWriter.cacheDirectory(for: meetingID)
        } catch {
            throw SummarizeStageError.transcriptMissing
        }
    }

    static func parseCaptureStartedAt(_ captureStartedAt: String?) throws -> Date {
        guard let captureStartedAt, let date = ISO8601UTC.date(from: captureStartedAt) else {
            throw SummarizeStageError.captureStartedAtMissing
        }
        return date
    }
}
