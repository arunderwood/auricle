import ArgumentParser
import Foundation

/// Every hand-printed CLI message bypasses `print(_:to:)`'s `stderr`
/// wrapper: `Decision 1.5`'s exit-code contract (0/1/2/3) is bespoke to this
/// app, not swift-argument-parser's own `ValidationError`/`EX_USAGE`
/// convention, so every error path here writes its own message and throws a
/// plain `ExitCode` rather than a type the framework would re-code.
///
/// `try?` rather than a propagated throw: this is already the diagnostic
/// output, so a broken stderr pipe has nothing further to report to — best
/// effort beats the uncaught Objective-C exception `FileHandle.write(_:)`
/// raises on a write failure.
func writeStderr(_ message: String) {
    try? FileHandle.standardError.write(contentsOf: Data((message + "\n").utf8))
}

/// Every stub verb's terminal action: none of the 10 MVP verbs has real
/// business logic yet (Story 1.7's own boundary), so each one's `run()`
/// converges on this single message-and-exit-2 path instead of repeating it.
func notYetImplemented(_ verbName: String) throws -> Never {
    writeStderr("\(verbName) is not yet implemented.")
    throw ExitCode(2)
}
