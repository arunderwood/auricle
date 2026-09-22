import Attribute
import Core
import DiarizerInterface
import Foundation

/// One frozen meeting the bench summarizes: the reference transcript plus the
/// directory the scorer reads `expected.json` from.
public struct RecallBenchFixture: Sendable, Equatable {
    public let id: String
    public let directory: URL
    public let transcript: CanonicalTranscript

    public init(id: String, directory: URL, transcript: CanonicalTranscript) {
        self.id = id
        self.directory = directory
        self.transcript = transcript
    }
}

/// Resolves the AMI manifest into loaded fixtures. The manifest is the single
/// list of meetings the bench and the regression suite share, so adding a
/// meeting to one adds it to the other.
public enum RecallBenchFixtureLoader {
    public enum LoadError: Error, Equatable, LocalizedError {
        case manifestUnreadable
        case manifestUndecodable
        case fixtureMissing(id: String)
        case transcriptUndecodable(id: String)
        case expectedItemsMissing(id: String)

        public var errorDescription: String? {
            switch self {
            case .manifestUnreadable:
                "cannot read \(manifestPath) under the given repo root"
            case .manifestUndecodable:
                "\(manifestPath) is not the expected JSON"
            case let .fixtureMissing(id):
                "the reference directory for \(id) does not exist"
            case let .transcriptUndecodable(id):
                "\(id)'s transcript.json is not a CanonicalTranscript"
            case let .expectedItemsMissing(id):
                "\(id)'s reference directory has no expected.json for the scorer to read"
            }
        }
    }

    /// Repo-relative, so a caller only supplies the repo root.
    public static let manifestPath = "Tests/regression/ami/manifest.json"

    /// Fixtures come back in manifest order, which is the order the report
    /// prints and the order the runner spends money in.
    ///
    /// `diarized: true` asks each fixture to carry real per-speaker labels
    /// instead of `transcript.json`'s own placeholder: when `diarization.json`
    /// and `attribution.json` sit beside it, they are joined in via the same
    /// `UtteranceSpeakers.resolve` the attribution sheet uses. A fixture
    /// missing either file falls back to the raw transcript, so a mixed
    /// repo root (some meetings diarized, some not) still loads.
    public static func load(repoRoot: URL, diarized: Bool = false) throws -> [RecallBenchFixture] {
        let manifestURL = repoRoot.appendingPathComponent(manifestPath)
        guard let data = try? Data(contentsOf: manifestURL) else {
            throw LoadError.manifestUnreadable
        }
        guard let manifest = try? JSONDecoder().decode(RecallBenchManifest.self, from: data) else {
            throw LoadError.manifestUndecodable
        }
        return try manifest.meetings.map { try fixture(for: $0, repoRoot: repoRoot, diarized: diarized) }
    }

    private static func fixture(for meeting: RecallBenchManifestMeeting, repoRoot: URL, diarized: Bool) throws -> RecallBenchFixture {
        let directory = repoRoot.appendingPathComponent(meeting.reference, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LoadError.fixtureMissing(id: meeting.id)
        }
        guard
            let data = try? Data(contentsOf: directory.appendingPathComponent("transcript.json")),
            let transcript = try? JSONDecoder().decode(CanonicalTranscript.self, from: data)
        else {
            throw LoadError.transcriptUndecodable(id: meeting.id)
        }
        // Checked here rather than at scoring time: the scorer runs only after
        // the meeting's paid call, so a fixture missing it would fail every
        // row of the run with nothing to show for the spend.
        guard FileManager.default.isReadableFile(atPath: directory.appendingPathComponent("expected.json").path) else {
            throw LoadError.expectedItemsMissing(id: meeting.id)
        }
        let resolvedTranscript = diarized ? (diarizedTranscript(in: directory, from: transcript) ?? transcript) : transcript
        return RecallBenchFixture(id: meeting.id, directory: directory, transcript: resolvedTranscript)
    }

    /// `nil` when `diarization.json` or `attribution.json` is missing or
    /// undecodable beside `transcript.json` — the caller falls back to the
    /// transcript as written.
    private static func diarizedTranscript(in directory: URL, from transcript: CanonicalTranscript) -> CanonicalTranscript? {
        guard
            let diarizationData = try? Data(contentsOf: directory.appendingPathComponent("diarization.json")),
            let diarization = try? JSONDecoder().decode(DiarizationArtifact.self, from: diarizationData),
            let attribution = try? AttributionFile.read(in: directory)
        else {
            return nil
        }
        let resolved = UtteranceSpeakers.resolve(utteranceCount: transcript.utterances.count, diarization: diarization, file: attribution)
        let textBytes = Array(transcript.text.utf8)
        let pairs = transcript.utterances.enumerated().map { index, utterance in
            (speakerLabel: resolved[index] ?? utterance.speakerLabel, text: body(of: utterance, textBytes: textBytes))
        }
        return CanonicalTranscriptBuilder.build(pairs)
    }

    /// One utterance's text with its own `<speakerLabel>: ` prefix removed —
    /// the same join `AttributionRenderer.utteranceText` performs per
    /// segment, done here per utterance so a resolved speaker label can
    /// replace the original one before the transcript is rebuilt.
    private static func body(of utterance: CanonicalTranscript.Utterance, textBytes: [UInt8]) -> String {
        guard utterance.start >= 0, utterance.start <= utterance.end, utterance.end <= textBytes.count else { return "" }
        var start = utterance.start
        let prefix = Array("\(utterance.speakerLabel): ".utf8)
        if utterance.end - start >= prefix.count, Array(textBytes[start ..< start + prefix.count]) == prefix {
            start += prefix.count
        } else if utterance.end - start == prefix.count - 1, Array(textBytes[start ..< utterance.end]) == Array(prefix.dropLast()) {
            start = utterance.end
        }
        return String(bytes: textBytes[start ..< utterance.end], encoding: .utf8) ?? ""
    }
}
