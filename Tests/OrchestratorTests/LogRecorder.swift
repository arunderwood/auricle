@testable import Core
import os

/// Collects what a `Log` would have sent to the unified log, so a test asserts
/// on the real, already-redacted message instead of parsing `log show`.
final class LogRecorder: Sendable {
    struct Record: Sendable, Equatable {
        let level: OSLogType
        let message: String
    }

    private let recorded = OSAllocatedUnfairLock<[Record]>(initialState: [])

    /// A `Log` whose every emission lands in `records`.
    var log: Log {
        Log(category: "test") { level, message in
            self.recorded.withLock { $0.append(Record(level: level, message: message)) }
        }
    }

    var records: [Record] {
        recorded.withLock { $0 }
    }
}
