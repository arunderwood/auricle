import AIReviewerInterface
import Core
import DiarizerInterface
import Foundation

/// What attribution reads from a meeting's cache directory. Only
/// `diarization.json` is required; every other artifact degrades to "none".
public struct AttributionInputs: Sendable {
    public let diarization: DiarizationArtifact
    public let suggestions: [DiarizationSuggestion]
    public let calendar: CalendarArtifact?
    /// The `attribution.json` already on disk, if any.
    public let existing: AttributionFile?

    public init(diarization: DiarizationArtifact, suggestions: [DiarizationSuggestion] = [], calendar: CalendarArtifact? = nil, existing: AttributionFile? = nil) {
        self.diarization = diarization
        self.suggestions = suggestions
        self.calendar = calendar
        self.existing = existing
    }

    private static let diarizationName = "diarization.json"
    private static let suggestionsName = DiarizationDependents.suggestionsFileName
    private static let calendarName = "calendar.json"

    public enum LoadError: Error, Equatable, Sendable {
        case diarizationUnreadable
        case attributionUnreadable
    }

    /// Throws `LoadError` when `diarization.json` is missing or undecodable, or when an
    /// `attribution.json` exists but cannot be decoded. A missing, empty or
    /// undecodable suggestions file and a missing or undecodable
    /// `calendar.json` are no suggestions and no calendar, not errors.
    public static func load(for meetingID: MeetingID) throws -> AttributionInputs {
        let directory = try CacheArtifactWriter.cacheDirectory(for: meetingID)
        let decoder = JSONDecoder()
        let diarization: DiarizationArtifact
        do {
            diarization = try decoder.decode(DiarizationArtifact.self, from: Data(contentsOf: directory.appendingPathComponent(diarizationName)))
        } catch {
            throw LoadError.diarizationUnreadable
        }
        let suggestions = (try? decoder.decode(
            AIReviewerResult<DiarizationSuggestion>.self,
            from: Data(contentsOf: directory.appendingPathComponent(suggestionsName)),
        ))?.suggestions ?? []
        let calendar = try? decoder.decode(CalendarArtifact.self, from: Data(contentsOf: directory.appendingPathComponent(calendarName)))
        let existing: AttributionFile?
        do {
            existing = try AttributionFile.read(in: directory)
        } catch {
            throw LoadError.attributionUnreadable
        }
        return AttributionInputs(diarization: diarization, suggestions: suggestions, calendar: calendar, existing: existing)
    }
}
