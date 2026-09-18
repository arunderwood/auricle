import Core
import Foundation

/// Reads `CanonicalTranscript` JSON fixtures from a directory. Every thrown
/// error carries at most a file name or directory path, never file contents:
/// the fixtures are real meeting transcripts.
public enum StrategyComparisonFixtureLoader {
    public enum LoadError: Error, Equatable, LocalizedError {
        case directoryUnreadable(path: String)
        case noTranscriptsFound(directory: String)
        /// The file could not be read or did not decode as a `CanonicalTranscript`.
        case malformedFixture(fileName: String)

        public var errorDescription: String? {
            switch self {
            case let .directoryUnreadable(path):
                "transcripts directory is missing or unreadable: \(path)"
            case let .noTranscriptsFound(directory):
                "no .json transcripts found in \(directory)"
            case let .malformedFixture(fileName):
                "\(fileName) could not be read as a CanonicalTranscript"
            }
        }
    }

    /// Every regular `.json` file directly inside `directory`, in filename
    /// order, named by file stem. Other files, hidden files and
    /// subdirectories are ignored. Throws `noTranscriptsFound` on an empty
    /// result so a caller can refuse before making any strategy call.
    public static func load(from directory: URL) throws -> [StrategyComparisonFixture] {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles],
            )
        } catch {
            throw LoadError.directoryUnreadable(path: directory.path)
        }

        let jsonFiles = entries
            .filter { $0.pathExtension.lowercased() == "json" && !isDirectory($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !jsonFiles.isEmpty else {
            throw LoadError.noTranscriptsFound(directory: directory.path)
        }

        return try jsonFiles.map { file in
            let transcript: CanonicalTranscript
            do {
                transcript = try JSONDecoder().decode(CanonicalTranscript.self, from: Data(contentsOf: file))
            } catch {
                throw LoadError.malformedFixture(fileName: file.lastPathComponent)
            }
            return StrategyComparisonFixture(name: file.deletingPathExtension().lastPathComponent, transcript: transcript)
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}
