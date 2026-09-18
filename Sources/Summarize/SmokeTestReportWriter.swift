import Core
import Foundation

/// Writes the two smoke-test reports into an output directory, each through
/// `AtomicWriter` so an interrupted run never leaves a half-written report.
public enum SmokeTestReportWriter {
    public static let metricsFileName = "results.md"
    public static let detailFileName = "detail.md"

    /// Creates `outputDirectory` if needed. Nothing is created before this
    /// call, so a run that refuses to start leaves no trace on disk.
    @discardableResult
    public static func write(
        rows: [SmokeTestRow],
        generatedAt: Date,
        modelIdentifier: String,
        to outputDirectory: URL,
    ) throws -> (metrics: URL, detail: URL) {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let metricsURL = outputDirectory.appendingPathComponent(metricsFileName)
        let detailURL = outputDirectory.appendingPathComponent(detailFileName)
        let metrics = SmokeTestReportRenderer.metricsReport(rows: rows, generatedAt: generatedAt, modelIdentifier: modelIdentifier)
        let detail = SmokeTestReportRenderer.detailReport(rows: rows, generatedAt: generatedAt, modelIdentifier: modelIdentifier)
        try AtomicWriter.write(Data(metrics.utf8), to: metricsURL)
        try AtomicWriter.write(Data(detail.utf8), to: detailURL)
        return (metricsURL, detailURL)
    }
}
