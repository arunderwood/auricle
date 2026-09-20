@testable import Core
import Foundation
import Testing

@Test func categoryIsPlumbedFromInitAndSubsystemIsLocked() {
    let log = Log(category: "transcribe")

    #expect(log.category == "transcribe")
    #expect(Log.subsystem == "com.auricle.app")
}

@Test func noFieldsLogsMessageAsIs() {
    let built = Log.buildMessage("meeting started", [:])

    #expect(built == "meeting started")
}

@Test func publicSafeValueAppearsVerbatim() {
    let built = Log.buildMessage("transcribe completed", ["duration": .publicSafe(1200)])

    #expect(built.contains("duration=1200"))
}

@Test func allLevelsCanBeCalledWithoutCrashing() {
    let log = Log(category: "transcribe")

    log.debug("debug message", ["count": .publicSafe(1)])
    log.info("info message")
    log.warn("warn message", ["reason": .publicSafe("stale")])
    log.error("error message", ["code": .publicSafe(500)])
}

/// Drives the public entry points, not `buildMessage`, so an edit that stopped
/// routing a level through redaction would fail here.
@Test func infoWarnAndErrorNeverDeliverASensitiveValueToTheSink() {
    let recorder = LogRecorder()
    let log = recorder.log
    let secret = "sk-live-abc123 /Users/someone/vault"
    let fields: [String: LogSensitivity] = ["token": .sensitive(secret), "count": .publicSafe(3)]

    log.info("info message", fields)
    log.warn("warn message", fields)
    log.error("error message", fields)

    let records = recorder.records
    #expect(records.map(\.level) == [.info, .default, .error])
    for record in records {
        #expect(!record.message.contains("sk-live-abc123"))
        #expect(!record.message.contains("/Users/someone"))
        #expect(record.message.contains("token=\(Log.redactionMarker)"))
        #expect(record.message.contains("count=3"))
    }
}

#if DEBUG
    @Test func debugNeverDeliversASensitiveValueToTheSink() {
        let recorder = LogRecorder()

        recorder.log.debug("debug message", ["body": .sensitive("raw response body")])

        #expect(recorder.records.map(\.level) == [.debug])
        #expect(recorder.records.allSatisfy { !$0.message.contains("raw response body") })
    }
#endif
