import AIReviewerInterface
import ClaudeSummarizer
import Core
import DiarizerInterface
import Foundation
import SummarizerInterface

/// One entry of the model's answer. `kind` stays a string so an unknown value
/// drops that entry instead of failing the whole decode.
private struct ClaudeDiarizationModelEntry: Decodable {
    let segmentID: String
    let kind: String
    let reasoning: String?
    let proposedSplits: [ProposedSplit]?

    enum CodingKeys: String, CodingKey {
        case segmentID = "segment_id"
        case kind
        case reasoning
        case proposedSplits = "proposed_splits"
    }
}

/// Phase 1 reviewer: one non-streaming Messages API call that flags segments
/// whose speaker labels look wrong. It writes nothing; the caller persists
/// the result.
public struct ClaudeDiarizationReviewer: DiarizationReviewerStrategy {
    public static let defaultModelID = "claude-haiku-4-5"

    private static let maxTokens = 4096
    /// Computed, not stored: `[String: Any]` is not `Sendable`.
    private static var cacheControl: [String: Any] {
        ["type": "ephemeral"]
    }

    private let httpClient: AnthropicHTTPClient
    private let log = Log(category: "claude-diarization-reviewer")

    public init(httpClient: AnthropicHTTPClient = AnthropicHTTPClient()) {
        self.httpClient = httpClient
    }

    public func review(
        input: DiarizationReviewInput,
        config: AIReviewerConfig,
    ) async throws -> AIReviewerResult<DiarizationSuggestion> {
        let prompt = DiarizationReviewPrompt.build(input: input)
        let body = try Self.buildRequestBody(prompt: prompt, modelID: config.modelID)
        let response = try await httpClient.send(AnthropicRequest(body: body))

        let entries: [Any]
        do {
            entries = try Self.decodeEntries(from: response.content)
        } catch {
            log.warn("diarization review answer failed to decode", [:])
            throw error
        }

        let suggestions = validated(entries, segments: input.diarization.segments)
        log.info("diarization review complete", [
            "segmentCount": .publicSafe(input.diarization.segments.count),
            "suggestionCount": .publicSafe(suggestions.count),
        ])

        return AIReviewerResult(
            suggestions: suggestions,
            cost: AIReviewerCost(
                inputTokens: response.usage.inputTokens,
                outputTokens: response.usage.outputTokens,
                costUSD: response.costUSD,
                modelID: response.model,
            ),
            reviewedSegmentCount: input.diarization.segments.count,
        )
    }

    /// Drops, rather than fails on, entries the model got wrong: the call is
    /// already paid for and the remaining flags are still useful. Drops are
    /// logged by index only.
    private func validated(_ entries: [Any], segments: [DiarizedSegment]) -> [DiarizationSuggestion] {
        let segmentsByID = Dictionary(segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let knownLabels = Set(segments.map(\.speakerLabel))
        var seen = Set<String>()
        var result: [DiarizationSuggestion] = []
        for (index, raw) in entries.enumerated() {
            guard
                JSONSerialization.isValidJSONObject(raw),
                let data = try? JSONSerialization.data(withJSONObject: raw),
                let entry = try? JSONDecoder().decode(ClaudeDiarizationModelEntry.self, from: data),
                let segment = segmentsByID[entry.segmentID],
                let kind = DiarizationSuggestion.Kind(rawValue: entry.kind)
            else {
                log.warn("dropping diarization suggestion: malformed, unknown segment or unknown kind", ["index": .publicSafe(index)])
                continue
            }
            let splits = entry.proposedSplits ?? []
            guard Self.splitsAreUsable(splits, kind: kind, segment: segment, knownLabels: knownLabels) else {
                log.warn("dropping diarization suggestion: splits do not fit the kind or segment", ["index": .publicSafe(index)])
                continue
            }
            let suggestionID = Self.suggestionID(segmentID: entry.segmentID, kind: kind)
            guard seen.insert(suggestionID).inserted else {
                log.warn("dropping duplicate diarization suggestion", ["index": .publicSafe(index)])
                continue
            }
            result.append(DiarizationSuggestion(
                suggestionId: suggestionID,
                reasoning: entry.reasoning ?? "",
                kind: kind,
                segmentId: entry.segmentID,
                proposedSplits: splits,
            ))
        }
        return result
    }

    /// An over-segmentation proposes a merge and carries no splits. An
    /// under-segmentation needs at least one split, each ordered, finite,
    /// inside the segment and labeled with a speaker already in use: the
    /// attribution sheet applies splits as given and cannot repair a bad one.
    private static func splitsAreUsable(
        _ splits: [ProposedSplit],
        kind: DiarizationSuggestion.Kind,
        segment: DiarizedSegment,
        knownLabels: Set<String>,
    ) -> Bool {
        switch kind {
        case .overSegmentation:
            splits.isEmpty
        case .underSegmentation:
            !splits.isEmpty && splits.allSatisfy { split in
                split.start.isFinite && split.end.isFinite
                    && split.start < split.end
                    && split.start >= segment.startSeconds && split.end <= segment.endSeconds
                    && knownLabels.contains(split.speakerLabel)
            }
        }
    }

    /// Derived from the segment and kind, never from the model, so the same
    /// flag keeps its id across reruns and sheet reopens.
    static func suggestionID(segmentID: String, kind: DiarizationSuggestion.Kind) -> String {
        let suffix = switch kind {
        case .underSegmentation: "under"
        case .overSegmentation: "over"
        }
        return "sug_\(segmentID)_\(suffix)"
    }

    /// Cache breakpoints are prefix boundaries: the system block and the
    /// instructions block are identical across meetings and carry
    /// `cache_control`; the meeting data is unique per call and comes last,
    /// uncached.
    private static func buildRequestBody(prompt: DiarizationReviewPrompt, modelID: String) throws -> Data {
        let body: [String: Any] = [
            "model": modelID,
            "max_tokens": maxTokens,
            "system": [
                ["type": "text", "text": prompt.system, "cache_control": cacheControl],
            ],
            "messages": [
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": prompt.instructions, "cache_control": cacheControl],
                        ["type": "text", "text": prompt.meetingData],
                    ],
                ],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    private static func decodeEntries(from content: Data) throws -> [Any] {
        guard let blocks = (try? JSONSerialization.jsonObject(with: content)) as? [[String: Any]] else {
            throw SummarizerError.malformedResponse
        }
        let text = blocks
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        let json = stripCodeFence(text)
        guard
            !json.isEmpty,
            let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
            let entries = object["suggestions"] as? [Any]
        else {
            throw SummarizerError.malformedResponse
        }
        return entries
    }

    /// Models often wrap JSON in a Markdown fence despite being told not to.
    static func stripCodeFence(_ text: String) -> String {
        var lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        guard let first = lines.first, first.hasPrefix("```") else {
            return lines.joined(separator: "\n")
        }
        lines.removeFirst()
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces) == "```" {
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
