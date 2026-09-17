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
