import AIReviewerInterface
import Foundation
import Testing

struct PromptCachingContractTests {
    @Test("system and instructions blocks are cached; the meeting data block and everything after a cached block is not")
    func markerPlacement() async throws {
        let endpoint = ReviewerTestSupport.uniqueEndpoint()
        _ = try await ReviewerTestSupport.run(answer: #"{"suggestions": []}"#, endpoint: endpoint)
        let body = try #require(ReviewerStubURLProtocol.capturedBody(for: endpoint))
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])

        let system = try #require(json["system"] as? [[String: Any]])
        #expect(system.count == 1)
        #expect((system[0]["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")

        let messages = try #require(json["messages"] as? [[String: Any]])
        let content = try #require(messages.first?["content"] as? [[String: Any]])
        #expect(content.count == 2)
        #expect((content[0]["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")

        let meeting = try #require(content.last)
        #expect(meeting["cache_control"] == nil)
        let meetingText = try #require(meeting["text"] as? String)
        #expect(meetingText.contains("[seg_1]"))
        #expect(meetingText.contains("Hello there."))
    }
}
