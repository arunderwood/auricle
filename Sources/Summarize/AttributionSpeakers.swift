import Attribute
import Core
import DiarizerInterface
import Foundation

/// Reads the speaker names out of `attribution.json` for the summarize stage.
/// Only the `speakers` object is read (`Speaker_N` to `[[Name]]`): the file's
/// other keys (`segment_overrides`, `segment_splits`) belong to other readers
/// and may grow without this one noticing.
enum AttributionSpeakers {
    static let fileName = AttributionArtifact.fileName

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
    /// as unmapped rather than surface as a blank speaker. A `Speaker_N` value
    /// is the same thing spelled out: `--publish-anyway` writes each speaker
    /// mapped to itself, and that names nobody.
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
        return speakers.filter {
            let value = $0.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return !value.isEmpty && !UtteranceSpeakers.isPlaceholder(value)
        }
    }

    private static let diarizationFileName = "diarization.json"

    /// The speaker of each utterance, joined from `diarization.json` and the
    /// whole of `attribution.json` (see `UtteranceSpeakers`). `nil` when there
    /// is no `diarization.json` to join through, so the caller falls back to
    /// each utterance's own label. A file that exists but cannot be decoded
    /// throws, as `read` does.
    static func utteranceSpeakers(in cacheDirectory: URL, utteranceCount: Int) throws -> [String?]? {
        let url = cacheDirectory.appendingPathComponent(diarizationFileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let diarization: DiarizationArtifact
        do {
            diarization = try JSONDecoder().decode(DiarizationArtifact.self, from: Data(contentsOf: url))
        } catch {
            throw SummarizeStageError.diarizationUndecodable
        }
        let file: AttributionFile?
        do {
            file = try AttributionFile.read(in: cacheDirectory)
        } catch {
            throw SummarizeStageError.attributionUndecodable
        }
        return UtteranceSpeakers.resolve(utteranceCount: utteranceCount, diarization: diarization, file: file)
    }

    /// The names attribution gave its speakers, brackets stripped, each once,
    /// in a fixed order. Glossary scoping matches these against the people in
    /// the vault, so an attendee who says nothing still keeps their term.
    static func attendeeNames(from speakers: [String: String]?) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for speaker in (speakers ?? [:]).keys.sorted() {
            let name = (speakers?[speaker] ?? "")
                .replacingOccurrences(of: "[[", with: "")
                .replacingOccurrences(of: "]]", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, seen.insert(name.lowercased()).inserted {
                names.append(name)
            }
        }
        return names
    }
}
