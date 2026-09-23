import Foundation
import Summarize
import Testing

/// The fixture runs the stage with Los Angeles as the current zone; the
/// default capture instant is 12:00Z, 05:00 in Los Angeles and 21:00 in Tokyo.
@Test func theGenericTitleUsesTheMeetingsCaptureZone() async throws {
    let fixture = try await StageFixture(captureTimeZone: "Asia/Tokyo")
    defer { fixture.cleanUp() }
    try fixture.plantTranscript()

    _ = try await fixture.run(primary: StageStubStrategy(.success(makeStageGrounded(dropCount: 0))))

    #expect(try fixture.readSummary().title.hasPrefix("Meeting at 2026-04-28T21:00 "))
}

@Test(arguments: [nil, "Not/AZone"])
func aMissingOrUnknownCaptureZoneTitlesTheMeetingInTheCurrentZone(zone: String?) async throws {
    let fixture = try await StageFixture(captureTimeZone: zone)
    defer { fixture.cleanUp() }
    try fixture.plantTranscript()

    _ = try await fixture.run(primary: StageStubStrategy(.success(makeStageGrounded(dropCount: 0))))

    #expect(try fixture.readSummary().title == stageExpectedTitle)
}
