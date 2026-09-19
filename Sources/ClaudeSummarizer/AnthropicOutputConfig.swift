import SummarizerInterface

/// The request-body fragment both strategies send, kept in one place so the
/// level a strategy sends is the level telemetry records.
enum AnthropicOutputConfig {
    /// `EffortLevel`'s raw values are the API's effort names, and the field
    /// takes no beta header. Omitting it means `high` on the API side, which
    /// is why the level is always sent explicitly.
    static func body(effort: EffortLevel) -> [String: Any] {
        ["effort": effort.rawValue]
    }
}
