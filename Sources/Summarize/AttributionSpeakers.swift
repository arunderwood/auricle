import Foundation

/// Reads the speaker names out of `attribution.json` for the summarize stage.
/// Only the `speakers` object is read (`Speaker_N` to `[[Name]]`): the file's
/// other keys (`segment_overrides`, `segment_splits`) belong to other readers
/// and may grow without this one noticing.
enum AttributionSpeakers {
    static let fileName = "attribution.json"

    /// The file, decoded for just the key this stage uses.
    private struct File: Decodable {
        let speakers: [String: String]
    }

    /// `nil` when the file does not exist: attribution has not happened, which
    /// is different from an attribution that named nobody. A file that exists
    /// but cannot be read or decoded throws, so a damaged attribution is never
    /// mistaken for an absent one.
    ///
    /// An empty or whitespace-only value is dropped: the schema defines it as
    /// "render as the `Speaker_N` placeholder" (Decision 5.4), so it must count
    /// as unmapped rather than surface as a blank speaker.
    static func read(in cacheDirectory: URL) throws -> [String: String]? {
        let url = cacheDirectory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let speakers: [String: String]
        do {
            let data = try Data(contentsOf: url)
            speakers = try JSONDecoder().decode(File.self, from: data).speakers
        } catch {
            throw SummarizeStageError.attributionUndecodable
        }
        return speakers.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
