import ArgumentParser
import Core
import Foundation
import Summarize

/// Reports the AI-correction wedge criterion (AR-AI-9): the share of the last
/// 30 days' meetings that show at least one jargon correction. Not a
/// user-facing verb: `shouldDisplay: false` keeps it out of `auricle help` and
/// shell completion, and it is run by hand. The logic lives in `Summarize`
/// (covered by `swift test`); this file only resolves the cache root and prints
/// the counts. It prints counts only, never meeting text.
struct JargonWedgeVerb: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__measure-jargon-wedge",
        abstract: "Count meetings from the last 30 days with an applied jargon correction and compare the rate with the 40% wedge criterion.",
        shouldDisplay: false,
    )

    @Option(help: "Cache root holding one directory per meeting. Default: the app's cache root.")
    var cacheRoot: String?

    func run() throws {
        let root: URL
        if let cacheRoot {
            root = URL(fileURLWithPath: (cacheRoot as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            do {
                root = try CacheArtifactWriter.cacheRoot()
            } catch {
                writeStderr("__measure-jargon-wedge: could not resolve the cache root (\(type(of: error))).")
                throw ExitCode(1)
            }
        }

        let report = JargonWedgeMeasurement.measure(cacheRoot: root)
        print("window_days: \(report.windowDays)")
        print("eligible_meetings: \(report.eligibleMeetings)")
        print("meetings_with_correction: \(report.meetingsWithCorrection)")
        print("missing_artifact_meetings: \(report.missingArtifactMeetings)")
        print("rate: \(report.rate.map { String(format: "%.3f", $0) } ?? "none")")
        print("criterion: \(JargonWedgeMeasurement.criterion) (\(report.meetsCriterion ? "met" : "not met"))")
    }
}
