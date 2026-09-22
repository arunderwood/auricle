import Core
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
    public static func load(repoRoot: URL) throws -> [RecallBenchFixture] {
        let manifestURL = repoRoot.appendingPathComponent(manifestPath)
        guard let data = try? Data(contentsOf: manifestURL) else {
            throw LoadError.manifestUnreadable
        }
        guard let manifest = try? JSONDecoder().decode(RecallBenchManifest.self, from: data) else {
            throw LoadError.manifestUndecodable
        }
        return try manifest.meetings.map { try fixture(for: $0, repoRoot: repoRoot) }
    }

    private static func fixture(for meeting: RecallBenchManifestMeeting, repoRoot: URL) throws -> RecallBenchFixture {
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
        return RecallBenchFixture(id: meeting.id, directory: directory, transcript: transcript)
    }
}
