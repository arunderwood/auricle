@testable import Core
import Foundation
import Testing

@Test func snakeCaseDialectRoundTripsAndUsesSnakeCaseKeys() throws {
    let value = CacheArtifactDialectExample(
        meetingId: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
    )

    let data = try JSONEncoder().encode(value)
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(json.contains("\"meeting_id\""))
    #expect(json.contains("\"created_at\""))
    #expect(!json.contains("\"meetingId\""))

    let decoded = try JSONDecoder().decode(CacheArtifactDialectExample.self, from: data)
    #expect(decoded == value)
}

@Test func camelCaseDialectRoundTripsAndUsesCamelCaseKeys() throws {
    let value = CLIOutputDialectExample(
        meetingId: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
    )

    let data = try JSONEncoder().encode(value)
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(json.contains("\"meetingId\""))
    #expect(json.contains("\"createdAt\""))
    #expect(!json.contains("\"meeting_id\""))

    let decoded = try JSONDecoder().decode(CLIOutputDialectExample.self, from: data)
    #expect(decoded == value)
}
