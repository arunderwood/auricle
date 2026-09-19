@testable import Core
import Foundation
import Testing

private func encodedObject(_ artifact: CalendarArtifact) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(artifact)) as? [String: Any])
}

@Test func aDegradedArtifactEncodesWithNoEventKey() throws {
    let object = try encodedObject(CalendarArtifact(degraded: true, event: nil))

    #expect(Set(object.keys) == ["degraded"])
    #expect(object["degraded"] as? Bool == true)
}

@Test func anEventArtifactEncodesSnakeCaseKeysAndNoEmail() throws {
    let artifact = CalendarArtifact(
        degraded: false,
        event: CalendarEventArtifact(
            eventID: "google:evt123",
            title: "Weekly Sync",
            start: "2026-04-28T12:00:00Z",
            end: "2026-04-28T13:00:00Z",
            attendees: [
                CalendarAttendeeArtifact(displayName: "Ada Lovelace", isSelf: true),
                CalendarAttendeeArtifact(displayName: nil, isSelf: false),
            ],
        ),
    )

    let object = try encodedObject(artifact)
    #expect(Set(object.keys) == ["degraded", "event"])
    let event = try #require(object["event"] as? [String: Any])
    #expect(Set(event.keys) == ["event_id", "title", "start", "end", "attendees"])
    let attendees = try #require(event["attendees"] as? [[String: Any]])
    #expect(Set(attendees[0].keys) == ["display_name", "is_self"])
    #expect(Set(attendees[1].keys) == ["is_self"])

    let decoded = try JSONDecoder().decode(CalendarArtifact.self, from: JSONEncoder().encode(artifact))
    #expect(decoded == artifact)
}

@Test func theArtifactWrittenThroughTheCacheWriterCarriesSchemaVersionOne() throws {
    let id = MeetingID.generate()
    defer {
        if let directory = try? CacheArtifactWriter.cacheDirectory(for: id) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    try CacheArtifactWriter.write(CalendarArtifact(degraded: true, event: nil), for: id, named: "calendar.json", schemaVersion: 1)

    let url = try CacheArtifactWriter.cacheDirectory(for: id).appendingPathComponent("calendar.json")
    let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    #expect(Set(object.keys) == ["degraded", "schema_version"])
    #expect(object["schema_version"] as? Int == 1)
}
