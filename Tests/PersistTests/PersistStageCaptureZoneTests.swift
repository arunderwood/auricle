import Core
import Foundation
@testable import Persist
@testable import State
import Testing

/// A generic-title summary, so the filename carries the `meeting-at-HHMM`
/// time as well as the date.
private let genericSummaryJSON = """
{
  "title": "Meeting",
  "calendar_event_title": null,
  "attendees": [],
  "self_wikilink": null,
  "needs_attribution": false,
  "needs_calendar_enrichment": true,
  "summary": "A summary paragraph.",
  "action_items": [],
  "decisions": [],
  "transcript_segments": []
}
"""

private func meetingRow(id: MeetingID, captureStartedAt: String, captureTimeZone: String?, vaultNotePath: String? = nil) -> Meeting {
    Meeting(
        id: id.rawValue,
        state: "persisting",
        createdAt: "2026-04-28T09:00:00Z",
        updatedAt: "2026-04-28T09:00:00Z",
        captureStartedAt: captureStartedAt,
        vaultNotePath: vaultNotePath,
        captureTimeZone: captureTimeZone,
    )
}

/// 03:30Z on the 28th is 20:30 on the 27th in Los Angeles and 12:30 on the
/// 28th in Tokyo, so the note says which zone it was rendered in.
@Test func theCaptureDateAndTimeUseTheMeetingsCaptureZoneOverTheCurrentZone() async throws {
    let fixture = try makeFixture(writeValidSummary: false)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    try writeSummaryJSON(genericSummaryJSON, to: fixture.cacheDirectory)
    let meetingID = MeetingID.generate()
    try await fixture.store.insertMeeting(meetingRow(id: meetingID, captureStartedAt: "2026-04-28T03:30:00Z", captureTimeZone: "America/Los_Angeles"))

    try await requireCompleted(fixture.run(meetingID: meetingID, clock: fixedTimeSource(at: firstRerunInstant, zone: "Asia/Tokyo")))

    let expectedURL = fixture.meetingsSubdirURL.appendingPathComponent("2026-04-27-meeting-at-2030.md")
    #expect(FileManager.default.fileExists(atPath: expectedURL.path))
    #expect(try String(contentsOf: expectedURL, encoding: .utf8).contains("date: 2026-04-27"))
}

@Test(arguments: [nil, "Not/AZone"])
func aMissingOrUnknownCaptureZoneFallsBackToTheCurrentZone(zone: String?) async throws {
    let fixture = try makeFixture(writeValidSummary: false)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    try writeSummaryJSON(genericSummaryJSON, to: fixture.cacheDirectory)
    let meetingID = MeetingID.generate()
    try await fixture.store.insertMeeting(meetingRow(id: meetingID, captureStartedAt: "2026-04-28T03:30:00Z", captureTimeZone: zone))

    try await requireCompleted(fixture.run(meetingID: meetingID, clock: fixedTimeSource(at: firstRerunInstant, zone: "Asia/Tokyo")))

    let expectedURL = fixture.meetingsSubdirURL.appendingPathComponent("2026-04-28-meeting-at-1230.md")
    #expect(FileManager.default.fileExists(atPath: expectedURL.path))
    #expect(try String(contentsOf: expectedURL, encoding: .utf8).contains("date: 2026-04-28"))
}

/// The re-run happens at 20:00Z on May 15th: still the 15th in Los Angeles,
/// already the 16th in Auckland. The suffix follows the current zone (Los
/// Angeles), not the zone the meeting was captured in (Auckland).
@Test func aRerunsDateSuffixUsesTheCurrentZoneEvenWhenTheCaptureZoneDiffers() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let originalURL = fixture.meetingsSubdirURL.appendingPathComponent("2026-04-29-tuesday-sync.md")
    try Data("---\ntitle: \"Tuesday Sync\"\n---\n\nOriginal body\n".utf8).write(to: originalURL)
    let meetingID = MeetingID.generate()
    try await fixture.store.insertMeeting(meetingRow(
        id: meetingID,
        captureStartedAt: captureStartedAtString,
        captureTimeZone: "Pacific/Auckland",
        vaultNotePath: originalURL.path,
    ))

    try await requireCompleted(fixture.run(
        meetingID: meetingID,
        clock: fixedTimeSource(at: "2026-05-15T20:00:00Z", zone: "America/Los_Angeles"),
    ))

    let rerunURL = fixture.meetingsSubdirURL.appendingPathComponent("2026-04-29-tuesday-sync--rerun-2026-05-15.md")
    #expect(FileManager.default.fileExists(atPath: rerunURL.path))
    #expect(try String(contentsOf: rerunURL, encoding: .utf8).contains("date: 2026-04-29"))
}
