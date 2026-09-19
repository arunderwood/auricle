import Core
import Foundation
import Testing

// MARK: - expected.json model

struct EvalExpectedSource: Decodable {
    let kind: String
    let title: String
    let origin: String
    let license: String
    let attribution: String
}

struct EvalExpectedItem: Decodable, Equatable {
    let text: String
    let quote: String
    let transcriptStart: Int
    let transcriptEnd: Int

    enum CodingKeys: String, CodingKey {
        case text
        case quote
        case transcriptStart = "transcript_start"
        case transcriptEnd = "transcript_end"
    }
}

/// The per-fixture thresholds a run is scored against, every key resolved.
struct EvalEffectiveTargets: Equatable {
    let minRecall: Double
    let maxFalseKeeps: Int
    let maxDropRate: Double
}

/// `expected.json`'s `targets` object as written: every key optional, so a
/// fixture states only the thresholds it overrides.
struct EvalTargets: Decodable, Equatable {
    static let defaultMinRecall = 0.8
    static let defaultMaxFalseKeeps = 1
    static let defaultMaxDropRate = 0.2

    let minRecall: Double?
    let maxFalseKeeps: Int?
    let maxDropRate: Double?

    enum CodingKeys: String, CodingKey {
        case minRecall = "min_recall"
        case maxFalseKeeps = "max_false_keeps"
        case maxDropRate = "max_drop_rate"
    }

    init(minRecall: Double? = nil, maxFalseKeeps: Int? = nil, maxDropRate: Double? = nil) {
        self.minRecall = minRecall
        self.maxFalseKeeps = maxFalseKeeps
        self.maxDropRate = maxDropRate
    }

    var effective: EvalEffectiveTargets {
        EvalEffectiveTargets(
            minRecall: minRecall ?? Self.defaultMinRecall,
            maxFalseKeeps: maxFalseKeeps ?? Self.defaultMaxFalseKeeps,
            maxDropRate: maxDropRate ?? Self.defaultMaxDropRate,
        )
    }
}

struct EvalExpectedFixture: Decodable {
    let schemaVersion: Int
    let source: EvalExpectedSource
    let speakers: [String: String]
    let actionItems: [EvalExpectedItem]
    let decisions: [EvalExpectedItem]
    let targets: EvalTargets?
    let notes: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case source
        case speakers
        case actionItems = "action_items"
        case decisions
        case targets
        case notes
    }

    var effectiveTargets: EvalEffectiveTargets {
        (targets ?? EvalTargets()).effective
    }
}

struct EvalFixture {
    let name: String
    let transcript: CanonicalTranscript
    let expected: EvalExpectedFixture
}

// MARK: - Loader

enum EvalFixtures {
    static var directory: URL? {
        Bundle.module.resourceURL?.appendingPathComponent("Fixtures/eval", isDirectory: true)
    }

    /// Every subdirectory holding a `transcript.json`, so a new fixture is
    /// covered by every suite that iterates these names the moment it is added.
    static var names: [String] {
        guard let directory,
              let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else {
            return []
        }
        return entries
            .filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).appendingPathComponent("transcript.json").path) }
            .sorted()
    }

    static func load(_ name: String) throws -> EvalFixture {
        let base = try #require(directory).appendingPathComponent(name, isDirectory: true)
        let transcript = try JSONDecoder().decode(CanonicalTranscript.self, from: Data(contentsOf: base.appendingPathComponent("transcript.json")))
        let expected = try JSONDecoder().decode(EvalExpectedFixture.self, from: Data(contentsOf: base.appendingPathComponent("expected.json")))
        return EvalFixture(name: name, transcript: transcript, expected: expected)
    }

    /// The UTF-8 byte range as text, or nil when it is out of bounds or splits
    /// a scalar, so a bad pointer fails an assertion instead of trapping.
    static func slice(_ bytes: [UInt8], _ start: Int, _ end: Int) -> String? {
        guard start >= 0, start <= end, end <= bytes.count else { return nil }
        return String(bytes: bytes[start ..< end], encoding: .utf8)
    }
}
