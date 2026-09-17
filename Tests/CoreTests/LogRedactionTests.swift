@testable import Core
import Foundation
import Testing

@Test func mixedFieldsRedactSensitiveAndKeepPublicSafeVerbatim() {
    let built = Log.buildMessage(
        "request completed",
        ["statusCode": .publicSafe(200), "authToken": .sensitive("sk-live-abc123")],
    )

    #expect(built.contains("statusCode=200"))
    #expect(built.contains("authToken=\(Log.redactionMarker)"))
    #expect(!built.contains("sk-live-abc123"))
}

@Test func fieldsAreComposedInSortedKeyOrderRegardlessOfInsertionOrder() {
    let built = Log.buildMessage(
        "meeting persisted",
        [
            "meetingId": .publicSafe("01ABC"),
            "attendeeEmail": .sensitive("user@example.com"),
            "durationMs": .publicSafe(4200),
        ],
    )

    #expect(built == "meeting persisted attendeeEmail=\(Log.redactionMarker) durationMs=4200 meetingId=01ABC")
}

@Test func apiResponseBodyFixtureNeverAppearsInBuiltMessage() {
    let rawResponseBody = """
    {"id":"msg_01XYZ","role":"assistant","content":[{"type":"text","text":"the user's SSN is 123-45-6789"}]}
    """

    let built = Log.buildMessage("anthropic response received", ["body": .sensitive(rawResponseBody)])

    #expect(!built.contains(rawResponseBody))
    #expect(!built.contains("123-45-6789"))
    #expect(built.contains("body=\(Log.redactionMarker)"))
}
