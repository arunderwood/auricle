import Foundation
import os

/// A field's sensitivity tag: every runtime value logged through `Log` must
/// carry one of these (AR-PAT-3). There is no untagged path for a runtime
/// value — a `Log` call's `message` is a `StaticString`, so it cannot
/// interpolate anything computed at runtime; the only way to log a variable
/// value is through `fields`, whose value type is `LogSensitivity`.
/// `.sensitive` values never reach the built message; `.publicSafe` values
/// do, verbatim.
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
    /// Receives the already-redacted message. Production writes it to
    /// `Logger` as `.public`, which is safe only because redaction has
    /// happened by the time this is called.
    private let sink: @Sendable (OSLogType, String) -> Void

    public init(category: String) {
        self.category = category
        let logger = Logger(subsystem: Log.subsystem, category: category)
        sink = { level, message in
            logger.log(level: level, "\(message, privacy: .public)")
        }
    }

    /// Replaces the `Logger` call, so a test sees exactly what would have
    /// reached the unified log without parsing `log show` output.
    init(category: String, sink: @escaping @Sendable (OSLogType, String) -> Void) {
        self.category = category
        self.sink = sink
    }

    /// Stripped in release builds: the body — including field redaction and
    /// message assembly — compiles to nothing outside `DEBUG`.
    public func debug(_ message: StaticString, _ fields: [String: LogSensitivity] = [:]) {
        #if DEBUG
            emit(.debug, message, fields)
        #endif
    }

    public func info(_ message: StaticString, _ fields: [String: LogSensitivity] = [:]) {
        emit(.info, message, fields)
    }

    /// OSLog has no warning type: `Logger.warning` is an alias for `.error`,
    /// which would make `warn` and `error` indistinguishable in `log show`.
    /// `warn` writes `.default` instead (what `Logger.notice` writes), which is
    /// persisted and shown without extra flags, like `.error`.
    public func warn(_ message: StaticString, _ fields: [String: LogSensitivity] = [:]) {
        emit(.default, message, fields)
    }

    public func error(_ message: StaticString, _ fields: [String: LogSensitivity] = [:]) {
        emit(.error, message, fields)
    }

    /// Single choke point for the "redact, then hand the sink an already-safe
    /// string" step every level above shares — so that invariant is
    /// enforced once, not re-stated at each call site.
    ///
    /// `message` is a `StaticString`, not a `String`: `StaticString` doesn't
    /// conform to `ExpressibleByStringInterpolation`, so a call site cannot
    /// write `"... \(runtimeValue)"` here — it's a compile error, not a
    /// review-dependent mistake. Every runtime value is forced through
    /// `fields`, where `LogSensitivity` is mandatory.
    private func emit(_ level: OSLogType, _ message: StaticString, _ fields: [String: LogSensitivity]) {
        sink(level, Log.buildMessage(String(describing: message), fields))
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
                case let .publicSafe(stringValue):
                    "\(key)=\(stringValue)"
                case .sensitive:
                    "\(key)=\(redactionMarker)"
                }
            }
            .joined(separator: " ")

        guard !message.isEmpty else { return rendered }
        return "\(message) \(rendered)"
    }
}
