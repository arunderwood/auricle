import AIReviewerInterface
import ClaudeAIReviewers
import Foundation
import SummarizerInterface
import Testing

struct ClaudeDiarizationReviewerTests {
    private let twoFlags = """
    {"suggestions": [
      {"segment_id": "seg_1", "kind": "under_segmentation", "reasoning": "two voices",
       "proposed_splits": [{"start": 0.0, "end": 1.0, "speaker_label": "Speaker_1"}, {"start": 1.0, "end": 2.0, "speaker_label": "Speaker_2"}]},
      {"segment_id": "seg_2", "kind": "over_segmentation", "reasoning": "same voice", "proposed_splits": []}
    ]}
    """

    @Test("two flags become suggestions with stable ids, cost and segment count")
    func flagsFound() async throws {
        let result = try await ReviewerTestSupport.run(answer: twoFlags)
        #expect(result.suggestions.map(\.suggestionId) == ["sug_seg_1_under", "sug_seg_2_over"])
        #expect(result.suggestions[0].proposedSplits.count == 2)
        #expect(result.reviewedSegmentCount == 2)
        #expect(result.cost.inputTokens == 1000)
        #expect(result.cost.outputTokens == 200)
        #expect(result.cost.modelID == "claude-haiku-4-5")
        #expect(abs(result.cost.costUSD - 0.002) < 1e-9)
    }

    @Test("ids are identical across reruns")
    func idStability() async throws {
        let first = try await ReviewerTestSupport.run(answer: twoFlags)
        let second = try await ReviewerTestSupport.run(answer: twoFlags)
        #expect(first.suggestions.map(\.suggestionId) == second.suggestions.map(\.suggestionId))
    }

    @Test("an empty list still records cost")
    func nothingFlagged() async throws {
        let result = try await ReviewerTestSupport.run(answer: #"{"suggestions": []}"#)
        #expect(result.suggestions.isEmpty)
        #expect(result.cost.inputTokens == 1000)
        #expect(result.reviewedSegmentCount == 2)
    }

    @Test("fenced JSON parses like unfenced")
    func fenced() async throws {
        let result = try await ReviewerTestSupport.run(answer: "```json\n\(twoFlags)\n```")
        #expect(result.suggestions.count == 2)
    }

    @Test("bad entries are dropped and the rest kept")
    func badEntries() async throws {
        let answer = """
        {"suggestions": [
          {"segment_id": "seg_99", "kind": "under_segmentation", "reasoning": "x", "proposed_splits": []},
          {"segment_id": "seg_1", "kind": "sideways", "reasoning": "x"},
          {"segment_id": "seg_2", "kind": "over_segmentation", "reasoning": "x",
           "proposed_splits": [{"start": 0, "end": 1, "speaker_label": "Speaker_1"}]},
          {"segment_id": "seg_1", "kind": "under_segmentation", "reasoning": "kept", "proposed_splits": [{"start": 0.0, "end": 1.0, "speaker_label": "Speaker_1"}]}
        ]}
        """
        let result = try await ReviewerTestSupport.run(answer: answer)
        #expect(result.suggestions.map(\.suggestionId) == ["sug_seg_1_under"])
    }

    @Test("a duplicate segment and kind keeps the first")
    func duplicate() async throws {
        let answer = """
        {"suggestions": [
          {"segment_id": "seg_1", "kind": "under_segmentation", "reasoning": "first", "proposed_splits": [{"start": 0.0, "end": 1.0, "speaker_label": "Speaker_1"}]},
          {"segment_id": "seg_1", "kind": "under_segmentation", "reasoning": "second", "proposed_splits": [{"start": 0.0, "end": 1.0, "speaker_label": "Speaker_1"}]}
        ]}
        """
        let result = try await ReviewerTestSupport.run(answer: answer)
        #expect(result.suggestions.count == 1)
        #expect(result.suggestions[0].reasoning == "first")
    }

    @Test("an undecodable answer throws malformedResponse")
    func undecodable() async {
        await #expect(throws: SummarizerError.malformedResponse) {
            _ = try await ReviewerTestSupport.run(answer: "not json at all")
        }
    }

    @Test("valid JSON without a suggestions key throws malformedResponse")
    func missingSuggestionsKey() async {
        await #expect(throws: SummarizerError.malformedResponse) {
            _ = try await ReviewerTestSupport.run(answer: #"{"flags": []}"#)
        }
    }

    @Test("under-segmentation splits that cannot be applied are dropped")
    func unusableSplits() async throws {
        let cases = [
            "[]",
            #"[{"start": 0.0, "end": 1.0, "speaker_label": "Speaker_9"}]"#,
            #"[{"start": 1.0, "end": 1.0, "speaker_label": "Speaker_1"}]"#,
            #"[{"start": 0.5, "end": 0.2, "speaker_label": "Speaker_1"}]"#,
            #"[{"start": 1.0, "end": 3.0, "speaker_label": "Speaker_1"}]"#,
            #"[{"start": -1.0, "end": 1.0, "speaker_label": "Speaker_1"}]"#,
        ]
        for splits in cases {
            let answer = #"{"suggestions": [{"segment_id": "seg_1", "kind": "under_segmentation", "reasoning": "x", "proposed_splits": \#(splits)}]}"#
            let result = try await ReviewerTestSupport.run(answer: answer)
            #expect(result.suggestions.isEmpty, "splits \(splits) should be dropped")
        }
    }

    @Test("a non-2xx status propagates the client error")
    func transportFailure() async throws {
        let endpoint = ReviewerTestSupport.uniqueEndpoint()
        ReviewerStubURLProtocol.register(url: endpoint, status: 401, body: Data())
        let reviewer = ReviewerTestSupport.makeReviewer(endpoint: endpoint)
        await #expect(throws: SummarizerError.self) {
            _ = try await reviewer.review(input: ReviewerTestSupport.makeInput(), config: AIReviewerConfig(modelID: "claude-haiku-4-5"))
        }
    }

    @Test("the request carries config.modelID and no stream flag")
    func requestBody() async throws {
        for model in ["claude-haiku-4-5", "claude-opus-5"] {
            let endpoint = ReviewerTestSupport.uniqueEndpoint()
            _ = try await ReviewerTestSupport.run(answer: #"{"suggestions": []}"#, endpoint: endpoint, model: model)
            let body = try #require(ReviewerStubURLProtocol.capturedBody(for: endpoint))
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["model"] as? String == model)
            #expect(json["stream"] == nil)
        }
    }

    @Test("the default model constant is haiku 4.5")
    func defaultModel() {
        #expect(ClaudeDiarizationReviewer.defaultModelID == "claude-haiku-4-5")
    }
}
