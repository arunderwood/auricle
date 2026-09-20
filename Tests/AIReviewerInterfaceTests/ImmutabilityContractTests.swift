import Foundation
import Testing

/// AR-AI-4: `transcript.json` and `diarization.json` are written once, by
/// the stage that produces them. Reviewers and every later stage only read
/// them; corrections live in `diarization_suggestions.json` and
/// `attribution.json`.
///
/// The scan is textual and per call site. It cannot follow a URL built on
/// one line and written on another, so code review covers that shape.
private enum ImmutableArtifactScan {
    static let owners: [String: String] = [
        "transcript.json": "Sources/Transcribe/",
        "diarization.json": "Sources/Diarize/",
    ]

    private nonisolated(unsafe) static let writeCall =
        #/(CacheArtifactWriter\.write|AtomicWriter\.write|\.write\(to|FileHandle\(forWriting|FileHandle\(forUpdating|createFile\(atPath|moveItem|copyItem|replaceItemAt)/#
    private nonisolated(unsafe) static let artifactConstant = #/(?:let|var)\s+(\w+)\b[^=\n]*=\s*"(transcript\.json|diarization\.json)"/#

    /// The immutable artifact names that `source` passes to a write call.
    static func writtenArtifacts(in source: String) -> Set<String> {
        var nameForToken: [String: String] = [:]
        for name in owners.keys {
            nameForToken["\"\(name)\""] = name
        }
        for match in source.matches(of: artifactConstant) {
            nameForToken[String(match.output.1)] = String(match.output.2)
        }

        var written: Set<String> = []
        for match in source.matches(of: writeCall) {
            let span = callText(in: source, from: match.range.lowerBound)
            for (token, name) in nameForToken where containsToken(token, in: span) {
                written.insert(name)
            }
        }
        return written
    }

    /// From `start` through the parenthesis that closes the first one at or
    /// after it, or to the end of the source when it never closes.
    private static func callText(in source: String, from start: String.Index) -> Substring {
        guard let open = source[start...].firstIndex(of: "(") else { return source[start...] }
        var depth = 0
        var index = open
        while index < source.endIndex {
            switch source[index] {
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 {
                    return source[start ... index]
                }
            default: break
            }
            index = source.index(after: index)
        }
        return source[start...]
    }

    private static func containsToken(_ token: String, in span: Substring) -> Bool {
        if token.hasPrefix("\"") {
            return span.contains(token)
        }
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: token))\\b"
        return span.range(of: pattern, options: .regularExpression) != nil
    }
}

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func swiftFiles(under directory: String) throws -> [(relativePath: String, text: String)] {
    let root = repoRoot.appendingPathComponent(directory)
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
        return []
    }
    var files: [(String, String)] = []
    for case let url as URL in enumerator where url.pathExtension == "swift" {
        let relative = String(url.path.dropFirst(repoRoot.path.count + 1))
        try files.append((relative, String(contentsOf: url, encoding: .utf8)))
    }
    return files
}

@Test func onlyTheProducingStageWritesAnImmutableArtifact() throws {
    let files = try swiftFiles(under: "Sources") + swiftFiles(under: "App")
    #expect(
        files.contains { $0.relativePath == "Sources/Transcribe/TranscribeStage.swift" },
        "the scan did not reach the sources, so an empty result would prove nothing",
    )

    var violations: [String] = []
    for (path, text) in files {
        for name in ImmutableArtifactScan.writtenArtifacts(in: text) {
            let owner = ImmutableArtifactScan.owners[name] ?? ""
            if !path.hasPrefix(owner) {
                violations.append("\(path) writes \(name); only \(owner) may")
            }
        }
    }
    #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
}

@Test func theOwningStageIsSeenWritingItsArtifact() throws {
    let transcribe = try #require(
        swiftFiles(under: "Sources/Transcribe").first { $0.relativePath.hasSuffix("TranscribeStage.swift") },
    )
    #expect(ImmutableArtifactScan.writtenArtifacts(in: transcribe.text) == ["transcript.json"])
}

@Test func aReaderThatWritesAnotherArtifactIsNotFlagged() throws {
    let summarize = try #require(
        swiftFiles(under: "Sources/Summarize").first { $0.relativePath.hasSuffix("SummarizeStage.swift") },
    )
    #expect(ImmutableArtifactScan.writtenArtifacts(in: summarize.text).isEmpty)
}

@Test(arguments: [
    #"try CacheArtifactWriter.write(value, for: id, named: "transcript.json", schemaVersion: 1)"#,
    #"try data.write(to: dir.appendingPathComponent("diarization.json"))"#,
    #"try AtomicWriter.write(data, to: cache.appendingPathComponent("transcript.json"))"#,
    #"let handle = try FileHandle(forWritingTo: dir.appendingPathComponent("diarization.json"))"#,
])
func theDetectorFlagsAWriteThatNamesAnImmutableArtifact(source: String) {
    #expect(!ImmutableArtifactScan.writtenArtifacts(in: source).isEmpty)
}

@Test func theDetectorResolvesAConstantNamingTheArtifact() {
    let source = """
    private static let artifact = "diarization.json"
    func save() throws {
        try CacheArtifactWriter.write(value, for: id, named: artifact, schemaVersion: 1)
    }
    """
    #expect(ImmutableArtifactScan.writtenArtifacts(in: source) == ["diarization.json"])
}

@Test func theDetectorIgnoresReadsAndOtherArtifacts() {
    let source = """
    let transcript = try Data(contentsOf: dir.appendingPathComponent("transcript.json"))
    try CacheArtifactWriter.write(value, for: id, named: "summary.json", schemaVersion: 1)
    """
    #expect(ImmutableArtifactScan.writtenArtifacts(in: source).isEmpty)
}

@Test(arguments: [
    #"try FileManager.default.moveItem(at: tmp, to: dir.appendingPathComponent("transcript.json"))"#,
    #"let h = try FileHandle(forUpdating: dir.appendingPathComponent("diarization.json"))"#,
])
func theDetectorFlagsMovesAndUpdatingHandles(source: String) {
    #expect(!ImmutableArtifactScan.writtenArtifacts(in: source).isEmpty)
}
