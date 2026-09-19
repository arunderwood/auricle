import Core
import Foundation

/// Writes the two comparison reports into an output directory, each through
/// `AtomicWriter` so an interrupted run never leaves a half-written report.
/// Both files are 0600: the detail report quotes transcript text, which for a
/// run over real meetings is private.
public enum StrategyComparisonReportWriter {
    public static let metricsFileName = "results.md"
    public static let detailFileName = "detail.md"

    /// Creates `outputDirectory` if needed. Nothing is created before this
    /// call, so a run that refuses to start leaves no trace on disk.
    @discardableResult
    public static func write(
        rows: [StrategyComparisonRow],
        generatedAt: Date,
        modelIdentifier: String,
        to outputDirectory: URL,
    ) throws -> (metrics: URL, detail: URL) {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let metricsURL = outputDirectory.appendingPathComponent(metricsFileName)
        let detailURL = outputDirectory.appendingPathComponent(detailFileName)
        let metrics = StrategyComparisonReportRenderer.metricsReport(rows: rows, generatedAt: generatedAt, modelIdentifier: modelIdentifier)
        let detail = StrategyComparisonReportRenderer.detailReport(rows: rows, generatedAt: generatedAt, modelIdentifier: modelIdentifier)
        try AtomicWriter.write(Data(metrics.utf8), to: metricsURL, permissions: 0o600)
        try AtomicWriter.write(Data(detail.utf8), to: detailURL, permissions: 0o600)
        return (metricsURL, detailURL)
    }
}
