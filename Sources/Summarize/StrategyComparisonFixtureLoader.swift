import Core
import Foundation

/// Reads `CanonicalTranscript` JSON fixtures from a directory, in either of
/// two layouts that can be mixed: a flat `<name>.json` file, or a
/// `<name>/transcript.json` subdirectory (the eval fixtures' layout, whose
/// `expected.json` and other files beside it are ignored). Every thrown error
/// carries at most a file name or directory path, never file contents: the
/// fixtures can be real meeting transcripts.
public enum StrategyComparisonFixtureLoader {
    public enum LoadError: Error, Equatable, LocalizedError {
        case directoryUnreadable(path: String)
        case noTranscriptsFound(directory: String)
        /// The file could not be read or did not decode as a `CanonicalTranscript`.
        /// A subdirectory fixture is named by its relative path,
        /// `<name>/transcript.json`.
        case malformedFixture(fileName: String)
        /// A flat `<name>.json` and a `<name>/` subdirectory both name one fixture.
        case duplicateFixtureName(name: String)

        public var errorDescription: String? {
            switch self {
            case let .directoryUnreadable(path):
                "transcripts directory is missing or unreadable: \(path)"
            case let .noTranscriptsFound(directory):
                "no transcripts found in \(directory) (expected <name>.json files or <name>/transcript.json)"
            case let .malformedFixture(fileName):
                "\(fileName) could not be read as a CanonicalTranscript"
            case let .duplicateFixtureName(name):
                "two fixtures are both named \(name): a \(name).json file and a \(name)/ directory"
            }
        }
    }

    static let directoryTranscriptFileName = "transcript.json"

    /// One fixture on disk: its name, the file to decode, and how errors name
    /// that file.
    private struct Source {
        let name: String
        let file: URL
        let displayName: String
    }

    /// Every fixture directly inside `directory`, in name order. A regular
    /// `.json` file is named by its stem; a subdirectory holding a regular
    /// `transcript.json` is named by the subdirectory. Everything else is
    /// ignored: other files, hidden entries, and subdirectories without a
    /// `transcript.json`. Throws `noTranscriptsFound` on an empty result so a
    /// caller can refuse before making any strategy call.
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

        let sources = entries.compactMap(source(for:)).sorted { $0.name < $1.name }
        guard !sources.isEmpty else {
            throw LoadError.noTranscriptsFound(directory: directory.path)
        }
        for (previous, next) in zip(sources, sources.dropFirst()) where previous.name == next.name {
            throw LoadError.duplicateFixtureName(name: next.name)
        }

        return try sources.map { source in
            let transcript: CanonicalTranscript
            do {
                transcript = try JSONDecoder().decode(CanonicalTranscript.self, from: Data(contentsOf: source.file))
            } catch {
                throw LoadError.malformedFixture(fileName: source.displayName)
            }
            return StrategyComparisonFixture(name: source.name, transcript: transcript)
        }
    }

    private static func source(for entry: URL) -> Source? {
        if isDirectory(entry) {
            let file = entry.appendingPathComponent(directoryTranscriptFileName)
            guard isRegularFile(file) else { return nil }
            let name = entry.lastPathComponent
            return Source(name: name, file: file, displayName: "\(name)/\(directoryTranscriptFileName)")
        }
        guard entry.pathExtension.lowercased() == "json" else { return nil }
        return Source(
            name: entry.deletingPathExtension().lastPathComponent,
            file: entry,
            displayName: entry.lastPathComponent,
        )
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }
}
