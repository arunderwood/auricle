import Foundation

/// A parsed `--arm` argument of the strategy-comparison verb: which strategy
/// an arm runs and, for a prompt comparison, which prompt directory it reads
/// instead of the bundled set. Pure data so the argument grammar is covered
/// by `swift test`; only the composition root turns a spec into a concrete
/// strategy.
///
/// Grammar: `citations`, `substring`, or `substring:<absolute prompt dir>`.
/// Two substring arms with different prompt directories are how the rig
/// answers "is prompt B better than prompt A".
public struct StrategyComparisonArmSpec: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case citations
        case substring
    }

    public enum ParseError: Error, Equatable, LocalizedError {
        case unknownStrategy(String)
        /// Only the substring strategy takes a prompt directory.
        case promptDirUnsupported(strategy: String)
        /// A relative directory would resolve against wherever the wrapper
        /// script changed to, not where the caller typed it.
        case promptDirNotAbsolute(String)
        case duplicateLabel(String)

        public var errorDescription: String? {
            switch self {
            case let .unknownStrategy(raw):
                "unknown arm '\(raw)': expected citations, substring or substring:<absolute prompt dir>"
            case let .promptDirUnsupported(strategy):
                "the \(strategy) arm takes no prompt directory"
            case let .promptDirNotAbsolute(path):
                "the prompt directory must be an absolute path (or start with ~): \(path)"
            case let .duplicateLabel(label):
                "two arms would both be labeled '\(label)'"
            }
        }
    }

    public let kind: Kind
    public let promptDir: URL?

    public init(kind: Kind, promptDir: URL? = nil) {
        self.kind = kind
        self.promptDir = promptDir
    }

    /// What the report prints for this arm, and what makes two arms distinct.
    public var label: String {
        guard let promptDir else { return kind.rawValue }
        return "\(kind.rawValue):\(promptDir.lastPathComponent)"
    }

    /// The Decision 3.6 pair, used when no `--arm` is given.
    public static let defaults = [
        StrategyComparisonArmSpec(kind: .citations),
        StrategyComparisonArmSpec(kind: .substring),
    ]

    public static func parse(_ raw: String) throws -> StrategyComparisonArmSpec {
        let parts = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let name = String(parts[0])
        guard let kind = Kind(rawValue: name) else {
            throw ParseError.unknownStrategy(raw)
        }
        guard parts.count == 2 else {
            return StrategyComparisonArmSpec(kind: kind)
        }
        guard kind == .substring else {
            throw ParseError.promptDirUnsupported(strategy: name)
        }
        let path = (String(parts[1]) as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else {
            throw ParseError.promptDirNotAbsolute(String(parts[1]))
        }
        return StrategyComparisonArmSpec(kind: kind, promptDir: URL(fileURLWithPath: path, isDirectory: true))
    }

    /// No arguments means `defaults`. Labels must be unique, because the
    /// reports key a row's cells by label.
    public static func parseAll(_ raws: [String]) throws -> [StrategyComparisonArmSpec] {
        guard !raws.isEmpty else { return defaults }
        let specs = try raws.map(parse)
        var seen = Set<String>()
        for spec in specs where !seen.insert(spec.label).inserted {
            throw ParseError.duplicateLabel(spec.label)
        }
        return specs
    }
}
