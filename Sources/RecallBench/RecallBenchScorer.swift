import Foundation

/// What `score.py note` prints. The matching rule behind these numbers lives
/// only in that script — Swift decodes the result and never re-derives it, so
/// the bench and the AMI regression suite can never disagree about what counts
/// as recalled.
public struct RecallBenchScore: Decodable, Sendable, Equatable {
    public let keptItems: Int
    public let ungroundedQuotes: Int
    public let expectedItems: Int
    public let recalledItems: Int
    public let falseKeeps: Int

    enum CodingKeys: String, CodingKey {
        case keptItems = "kept_items"
        case ungroundedQuotes = "ungrounded_quotes"
        case expectedItems = "expected_items"
        case recalledItems = "recalled_items"
        case falseKeeps = "false_keeps"
    }

    public init(keptItems: Int, ungroundedQuotes: Int, expectedItems: Int, recalledItems: Int, falseKeeps: Int) {
        self.keptItems = keptItems
        self.ungroundedQuotes = ungroundedQuotes
        self.expectedItems = expectedItems
        self.recalledItems = recalledItems
        self.falseKeeps = falseKeeps
    }
}

/// Runs `score.py note` over one rendered note and decodes its JSON.
public struct RecallBenchScorer: Sendable {
    /// Takes the script URL and the script's positional arguments, returns
    /// its stdout. Injectable so `swift test` covers the decode and the error
    /// paths without Python on the machine.
    public typealias Runner = @Sendable (URL, [String]) throws -> Data

    public enum ScoreError: Error, Equatable, LocalizedError {
        case scorerFailed(status: Int32, stderr: String)
        case scoreUndecodable

        public var errorDescription: String? {
            switch self {
            case let .scorerFailed(status, stderr):
                "score.py exited \(status): \(stderr)"
            case .scoreUndecodable:
                "score.py printed something that is not a score object"
            }
        }
    }

    private let scriptURL: URL
    private let runner: Runner

    public init(scriptURL: URL, runner: @escaping Runner = RecallBenchScorer.python3Runner) {
        self.scriptURL = scriptURL
        self.runner = runner
    }

    public func score(notePath: URL, expectedPath: URL, transcriptPath: URL) throws -> RecallBenchScore {
        let stdout = try runner(scriptURL, ["note", notePath.path, expectedPath.path, transcriptPath.path])
        guard let score = try? JSONDecoder().decode(RecallBenchScore.self, from: stdout) else {
            throw ScoreError.scoreUndecodable
        }
        return score
    }

    /// The same score, reached from an async caller without blocking the
    /// thread it is called on.
    ///
    /// `score` waits on a subprocess's pipes and exit. Swift concurrency runs
    /// async work on a cooperative pool exactly as wide as the machine's core
    /// count, and a thread blocked in `read` is a thread that pool cannot
    /// reclaim, so enough concurrent scorers starve it and every task in the
    /// process stops — including ones that never touch this type. A CI runner
    /// with four cores reaches that point; a developer's machine often does
    /// not, which is what makes the failure look machine-specific. Hopping to
    /// a `DispatchQueue` thread keeps the blocking where blocking is allowed.
    public func score(notePath: URL, expectedPath: URL, transcriptPath: URL) async throws -> RecallBenchScore {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result {
                    try score(notePath: notePath, expectedPath: expectedPath, transcriptPath: transcriptPath)
                })
            }
        }
    }

    /// `/usr/bin/env python3` rather than an absolute interpreter path: the
    /// repo pins its toolchain through `mise`, so the Python on `PATH` is the
    /// one the rest of the suite runs.
    public static let python3Runner: Runner = { scriptURL, arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", scriptURL.path] + arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        // The scorer reads its inputs by path and never from stdin; inheriting
        // the parent's would let a script that ever blocks on a read hang a
        // run whose calls are already paid for.
        process.standardInput = FileHandle.nullDevice
        try process.run()

        // Both pipes are drained before waiting, and concurrently: a child
        // that fills either 64 KiB pipe buffer blocks on write forever if the
        // parent is waiting for exit, or is draining only the other pipe.
        // `group.wait()` is the only read of `errorData`, and it happens after
        // the writing task has finished.
        nonisolated(unsafe) var errorData = Data()
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) {
            errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        let errorText = String(bytes: errorData, encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ScoreError.scorerFailed(status: process.terminationStatus, stderr: errorText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }
}
