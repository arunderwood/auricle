import Core

/// NFR-C1's per-meeting cost ceiling, recorded and never enforced: the call
/// has been paid for by the time its cost is known, so passing the ceiling
/// flags the run and warns, and the summary is kept.
enum CostCeiling {
    private static let log = Log(category: "summarize-stage")

    /// NFR-C1 states the ceiling as "at most", so a cost equal to it is within it.
    static func isExceeded(costUSD: Double, ceilingUSD: Double) -> Bool {
        costUSD > ceilingUSD
    }

    static func warnIfExceeded(costUSD: Double, ceilingUSD: Double) {
        guard isExceeded(costUSD: costUSD, ceilingUSD: ceilingUSD) else { return }
        log.warn("summarize cost passed the per-meeting ceiling", warningFields(costUSD: costUSD, ceilingUSD: ceilingUSD))
    }

    /// Pure, so a test can see that only the two amounts reach the log line.
    static func warningFields(costUSD: Double, ceilingUSD: Double) -> [String: LogSensitivity] {
        ["costUSD": .publicSafe(costUSD), "costCeilingUSD": .publicSafe(ceilingUSD)]
    }
}
