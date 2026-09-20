@testable import Core
import Foundation
import Testing

private let legacyJSON = """
{
  "title": "Sync",
  "calendar_event_title": null,
  "attendees": [],
  "needs_attribution": true,
  "needs_calendar_enrichment": true,
  "summary": "s",
  "action_items": [],
  "decisions": [],
  "transcript_segments": []
}
"""

@Test func aSummaryWithoutTheNeedsSummaryKeyDecodesAsComplete() throws {
    let artifact = try JSONDecoder().decode(SummaryArtifact.self, from: Data(legacyJSON.utf8))

    #expect(artifact.needsSummary == false)
}

@Test func needsSummaryRoundTripsUnderItsSnakeCaseKey() throws {
    let artifact = SummaryArtifact(
        title: "Sync", calendarEventTitle: nil, attendees: [], selfWikilink: nil,
        needsAttribution: true, needsCalendarEnrichment: true, needsSummary: true,
        summary: "", actionItems: [], decisions: [], transcriptSegments: [],
    )

    let data = try JSONEncoder().encode(artifact)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(object["needs_summary"] as? Bool == true)
    #expect(try JSONDecoder().decode(SummaryArtifact.self, from: data) == artifact)
}

@Test func persistMayCompleteIntoPublishedPartial() {
    let targets = PipelineTransitions.allowedTargets(stage: .persist, activeState: .persisting)

    #expect(targets == [.published, .publishedPartial, .persistFailed])
}
