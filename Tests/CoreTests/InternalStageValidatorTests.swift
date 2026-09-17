import Core
import Foundation
import Testing

@Test func validStageAndMatchingVersionValidates() {
    let outcome = InternalStageValidator.validate(
        stage: "transcribe",
        workerProtocolVersion: 1,
        expectedProtocolVersion: 1,
    )

    #expect(outcome == .valid)
}

@Test func unrecognizedStageIsRejectedBeforeCheckingProtocolVersion() {
    let outcome = InternalStageValidator.validate(
        stage: "bogus",
        workerProtocolVersion: 1,
        expectedProtocolVersion: 1,
    )

    #expect(outcome == .unknownStage("bogus"))
}

@Test func mismatchedProtocolVersionNamesExpectedAndReceived() {
    let outcome = InternalStageValidator.validate(
        stage: "transcribe",
        workerProtocolVersion: 99,
        expectedProtocolVersion: 1,
    )

    #expect(outcome == .protocolVersionMismatch(WorkerProtocolVersionMismatch(expected: 1, received: 99)))
}

@Test func mismatchPayloadEncodesTheExactExpectedJSONFieldNamesAndValues() throws {
    let mismatch = WorkerProtocolVersionMismatch(expected: 1, received: 99)

    let data = try JSONEncoder().encode(mismatch)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(object["error"] as? String == "worker_protocol_version_mismatch")
    #expect(object["expected"] as? Int == 1)
    #expect(object["received"] as? Int == 99)
    #expect(object.count == 3)
}

@Test func defaultExpectedProtocolVersionIsTheSharedCurrentConstant() {
    let outcome = InternalStageValidator.validate(stage: "transcribe", workerProtocolVersion: WorkerProtocolVersion.current)

    #expect(outcome == .valid)
}
