import Core
import Foundation

/// Where a per-segment correction came from.
public enum AttributionSource: Equatable, Sendable {
    case manual
    case aiSuggestion(suggestionId: String)
}

/// One paragraph the user reassigned to a speaker other than the default
/// mapping's. `speaker` is `[[Name]]` or a `Speaker_N` literal.
public struct SegmentOverride: Codable, Equatable, Sendable {
    public let segmentId: String
    public let speaker: String

    public init(segmentId: String, speaker: String) {
        self.segmentId = segmentId
        self.speaker = speaker
    }

    /// `applied_from` is always `manual` for an override, so it is written
    /// for other readers of the file and never read back.
    enum CodingKeys: String, CodingKey {
        case segmentId = "segment_id"
        case speaker
        case appliedFrom = "applied_from"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        segmentId = try container.decode(String.self, forKey: .segmentId)
        speaker = try container.decode(String.self, forKey: .speaker)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(segmentId, forKey: .segmentId)
        try container.encode(speaker, forKey: .speaker)
        try container.encode("manual", forKey: .appliedFrom)
    }
}

/// A replacement sub-segment inside a `SegmentSplit`, in seconds from the
/// start of the audio.
public struct SplitPart: Codable, Equatable, Sendable {
    public let newId: String
    public let start: Double
    public let end: Double
    public let speaker: String

    public init(newId: String, start: Double, end: Double, speaker: String) {
        self.newId = newId
        self.start = start
        self.end = end
        self.speaker = speaker
    }

    enum CodingKeys: String, CodingKey {
        case newId = "new_id"
        case start
        case end
        case speaker
    }
}

/// One split of an immutable `diarization.json` segment into two or more
/// replacement sub-segments.
public struct SegmentSplit: Codable, Equatable, Sendable {
    public let originalSegmentId: String
    public let source: AttributionSource
    public let splits: [SplitPart]

    public init(originalSegmentId: String, source: AttributionSource, splits: [SplitPart]) {
        self.originalSegmentId = originalSegmentId
        self.source = source
        self.splits = splits
    }

    enum CodingKeys: String, CodingKey {
        case originalSegmentId = "original_segment_id"
        case appliedFrom = "applied_from"
        case suggestionId = "suggestion_id"
        case splits
    }

    private static let manualTag = "manual"
    private static let aiSuggestionTag = "ai_suggestion"

    /// An unrecognized `applied_from`, or an `ai_suggestion` with no
    /// `suggestion_id`, reads as manual: a reader must survive a value a
    /// later writer adds.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        originalSegmentId = try container.decode(String.self, forKey: .originalSegmentId)
        splits = try container.decode([SplitPart].self, forKey: .splits)
        let tag = try container.decodeIfPresent(String.self, forKey: .appliedFrom)
        let suggestionId = try container.decodeIfPresent(String.self, forKey: .suggestionId)
        if tag == Self.aiSuggestionTag, let suggestionId {
            source = .aiSuggestion(suggestionId: suggestionId)
        } else {
            source = .manual
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(originalSegmentId, forKey: .originalSegmentId)
        switch source {
        case .manual:
            try container.encode(Self.manualTag, forKey: .appliedFrom)
            try container.encodeNil(forKey: .suggestionId)
        case let .aiSuggestion(suggestionId):
            try container.encode(Self.aiSuggestionTag, forKey: .appliedFrom)
            try container.encode(suggestionId, forKey: .suggestionId)
        }
        try container.encode(splits, forKey: .splits)
    }
}

/// The contents of `attribution.json` (Decision 5.4). Every key but `speakers`
/// is optional on read, and unknown keys are ignored, so a file written by a
/// later version still loads.
public struct AttributionFile: Codable, Equatable, Sendable {
    public static let fileName = AttributionArtifact.fileName
    public static let currentSchemaVersion = 1

    /// `Speaker_N` to `[[Name]]`, or to the `Speaker_N` literal when
    /// unattributed.
    public var speakers: [String: String]
    public var segmentOverrides: [SegmentOverride]
    public var segmentSplits: [SegmentSplit]

    public init(speakers: [String: String] = [:], segmentOverrides: [SegmentOverride] = [], segmentSplits: [SegmentSplit] = []) {
        self.speakers = speakers
        self.segmentOverrides = segmentOverrides
        self.segmentSplits = segmentSplits
    }

    enum CodingKeys: String, CodingKey {
        case speakers
        case segmentOverrides = "segment_overrides"
        case segmentSplits = "segment_splits"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        speakers = try container.decodeIfPresent([String: String].self, forKey: .speakers) ?? [:]
        segmentOverrides = try container.decodeIfPresent([SegmentOverride].self, forKey: .segmentOverrides) ?? []
        segmentSplits = try container.decodeIfPresent([SegmentSplit].self, forKey: .segmentSplits) ?? []
    }

    /// `nil` when the file does not exist. A file that exists but cannot be
    /// decoded throws, so damage is never mistaken for absence.
    public static func read(in cacheDirectory: URL) throws -> AttributionFile? {
        let url = cacheDirectory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(AttributionFile.self, from: Data(contentsOf: url))
    }

    public func write(for meetingID: MeetingID) throws {
        try CacheArtifactWriter.write(self, for: meetingID, named: Self.fileName, schemaVersion: Self.currentSchemaVersion)
    }
}
