import Foundation

/// The cache artifacts that describe one particular `diarization.json`: the
/// speaker labels and segment ids they hold mean nothing against another one.
/// In `Core` because the step that rewrites `diarization.json` and the stages
/// that read these must not depend on each other.
public enum DiarizationDependents {
    public static let suggestionsFileName = "diarization_suggestions.json"

    static let fileNames = [AttributionArtifact.fileName, suggestionsFileName]

    /// Removes every dependent from `directory`. A file that is not there is
    /// already gone; any other failure throws, because a survivor would be
    /// read against the new diarization.
    public static func remove(in directory: URL) throws {
        for name in fileNames {
            do {
                try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            } catch CocoaError.fileNoSuchFile {
                continue
            }
        }
    }
}
