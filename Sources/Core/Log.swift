import Foundation
import os

/// A field's sensitivity tag: every entry in a `Log` call's `fields`
/// dictionary must carry one of these — the dictionary's value type itself
/// has no untagged path (AR-PAT-3). `.sensitive` values never reach the
/// built message; `.publicSafe` values do, verbatim.
public enum LogSensitivity: Sendable {
    case publicSafe(String)
    case sensitive(String)

    /// Accepts any `CustomStringConvertible` so a call site can tag a value
    /// directly (a duration, a count, a `MeetingID`) without a manual
    /// `.description` call.
    public static func publicSafe(_ value: some CustomStringConvertible) -> LogSensitivity {
        .publicSafe(value.description)
    }

    public static func sensitive(_ value: some CustomStringConvertible) -> LogSensitivity {
        .sensitive(value.description)
    }
}

/// The sole logging interface (AR-PAT-3, AR-PAT-4): every log emission in the
/// app goes through a `Log` instance under the one locked subsystem, so
/// `log show --predicate 'subsystem == "com.auricle.app"'` is a complete
/// operational surface.
///
/// `.sensitive` fields are replaced by a fixed marker before the message
/// string is built, rather than routed through OSLog's own `%{private}@`
/// privacy modifier. That modifier only takes effect on a literal,
/// compile-time interpolation written at the call site — a shared wrapper
/// like this one builds its message from a runtime dictionary, so
/// OSLog's per-interpolation privacy can't apply here. Redacting before the
/// string exists means the built string is always safe to hand to `Logger`
/// as `.public`.
public struct Log: Sendable {
    static let subsystem = "com.auricle.app"
    static let redactionMarker = "<redacted>"

    let category: String
    private let logger: Logger

    public init(category: String) {
        self.category = category
        logger = Logger(subsystem: Log.subsystem, category: category)
    }

    /// Stripped in release builds: the body — including field redaction and
    /// message assembly — compiles to nothing outside `DEBUG`.
    public func debug(_ message: String, _ fields: [String: LogSensitivity] = [:]) {
        #if DEBUG
        emit(.debug, message, fields)
        #endif
    }

    public func info(_ message: String, _ fields: [String: LogSensitivity] = [:]) {
        emit(.info, message, fields)
    }

    /// `warn` has no distinct `OSLogType` of its own; this maps to `.notice`
    /// (OSLog's `.default` type) — persisted and visible in `log show`
    /// without special flags, one step below `.error`.
    public func warn(_ message: String, _ fields: [String: LogSensitivity] = [:]) {
        emit(.default, message, fields)
    }

    public func error(_ message: String, _ fields: [String: LogSensitivity] = [:]) {
        emit(.error, message, fields)
    }

    /// Single choke point for the "redact, then hand `Logger` an already-safe
    /// `.public` string" step every level above shares — so that invariant is
    /// enforced once, not re-stated at each call site.
    private func emit(_ level: OSLogType, _ message: String, _ fields: [String: LogSensitivity]) {
        let built = Log.buildMessage(message, fields)
        logger.log(level: level, "\(built, privacy: .public)")
    }

    /// Pure message-building step, kept separate from the `Logger` calls
    /// above so redaction is directly testable without parsing `log show`
    /// output. Fields are sorted by key so the result is deterministic —
    /// `[String: LogSensitivity]` iteration order is not.
    static func buildMessage(_ message: String, _ fields: [String: LogSensitivity]) -> String {
        guard !fields.isEmpty else { return message }

        let rendered = fields
            .sorted { $0.key < $1.key }
            .map { key, value -> String in
                switch value {
                case .publicSafe(let stringValue):
                    return "\(key)=\(stringValue)"
                case .sensitive:
                    return "\(key)=\(redactionMarker)"
                }
            }
            .joined(separator: " ")

        guard !message.isEmpty else { return rendered }
        return "\(message) \(rendered)"
    }
}
