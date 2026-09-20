import ArgumentParser

// The argument surface of the ten MVP verbs (Decision 1.5, NFR-I7): every
// verb name and flag here is a binding product contract, so the declarations
// live where `swift test` reaches them. Each `auricle-cli` verb reads its
// command line as an `@OptionGroup` of the matching type, so the flags the
// tests parse are the flags the verb declares.
//
// A flag's spelling comes from its property name, `publishAnyway` becoming
// `--publish-anyway`, so renaming a property renames the contract.
// `doctor` takes no arguments and has no type here.

/// `auricle record [<id>] [--replace] [--quiet]`.
public struct RecordArguments: ParsableArguments {
    @Argument(help: "Meeting ID to use. A new one is generated if omitted.")
    public var id: String?

    @Flag(help: "Reuse <id> even if captured audio already exists for it.")
    public var replace = false

    @Flag(help: "Suppress stdout output; exit code only.")
    public var quiet = false

    public init() {}
}

/// `auricle stop [--quiet]`.
public struct StopArguments: ParsableArguments {
    @Flag(help: "Suppress stdout output; exit code only.")
    public var quiet = false

    public init() {}
}

/// `auricle discard <id> [--quiet]`.
public struct DiscardArguments: ParsableArguments {
    @Argument(help: "Meeting ID.")
    public var id: String

    @Flag(help: "Suppress stdout output; exit code only.")
    public var quiet = false

    public init() {}
}

/// `auricle run <id> [--force] [--from <stage>] [--to <stage>] [--only <stage>]
/// [--reattribute] [--publish-anyway]`.
public struct RunArguments: ParsableArguments {
    @Argument(help: "Meeting ID.")
    public var id: String

    @Flag(help: "Re-run all stages from the beginning, even if already published.")
    public var force = false

    /// Plain strings, not `PipelineStage`, per Decision 1.5: the orthogonal
    /// stage-control flags must keep working unmodified as later epics add
    /// pipeline stages, without this argument surface needing a rebuild.
    @Option(help: "Run forward starting at <stage>.")
    public var from: String?

    @Option(help: "Run forward up to and including <stage>.")
    public var to: String?

    @Option(help: "Run only <stage>.")
    public var only: String?

    @Flag(help: "Alias for --from attribute; preserves the armed retention timer.")
    public var reattribute = false

    @Flag(help: "Skip attribution and publish with Speaker_N placeholder names.")
    public var publishAnyway = false

    public init() {}

    /// Rejects flag conflicts at parse time, so a bad combination never
    /// reaches the runner. `RunArgumentsError` is not a `ValidationError`
    /// because ArgumentParser exits 64 for that type, and Decision 1.5 says 1.
    public mutating func validate() throws {
        _ = try options()
    }

    /// The flags as typed values, or the first conflict found.
    public func options() throws -> RunOptions {
        let fromStage = try Self.stage(from, flag: "--from")
        let toStage = try Self.stage(to, flag: "--to")
        let onlyStage = try Self.stage(only, flag: "--only")

        if fromStage != nil, onlyStage != nil {
            throw RunArgumentsError.conflict("--from and --only cannot be combined.")
        }
        if toStage != nil, onlyStage != nil {
            throw RunArgumentsError.conflict("--to and --only cannot be combined.")
        }
        if publishAnyway {
            if fromStage == .attribute || onlyStage == .attribute {
                throw RunArgumentsError.conflict("--publish-anyway skips attribution, so it cannot be combined with --from attribute or --only attribute.")
            }
            if reattribute {
                throw RunArgumentsError.conflict("--publish-anyway skips attribution, so it cannot be combined with --reattribute.")
            }
        }
        if reattribute, fromStage != nil || onlyStage != nil {
            throw RunArgumentsError.conflict("--reattribute already means --from attribute, so it cannot be combined with --from or --only.")
        }
        if let fromStage, let toStage, fromStage > toStage {
            throw RunArgumentsError.conflict("--from \(fromStage.rawValue) comes after --to \(toStage.rawValue).")
        }
        return RunOptions(
            force: force,
            from: fromStage,
            to: toStage,
            only: onlyStage,
            reattribute: reattribute,
            publishAnyway: publishAnyway,
        )
    }

    private static func stage(_ raw: String?, flag: String) throws -> RunStage? {
        guard let raw else { return nil }
        guard let stage = RunStage(rawValue: raw) else {
            let known = RunStage.allCases.map(\.rawValue).joined(separator: ", ")
            throw RunArgumentsError.conflict("\(flag) '\(raw)' is not a stage. Stages: \(known).")
        }
        return stage
    }
}

/// A `RunArguments` combination that cannot run. The process exits 1.
public enum RunArgumentsError: Error, CustomStringConvertible, Equatable {
    case conflict(String)

    public var description: String {
        switch self {
        case let .conflict(message): message
        }
    }
}

/// `auricle attribute <id> [--batch] [--speakers "1=Ben,2=Sara"]`.
public struct AttributeArguments: ParsableArguments {
    @Argument(help: "Meeting ID.")
    public var id: String

    @Flag(help: "Apply the last-known speaker mapping instead of opening the GUI.")
    public var batch = false

    @Option(help: "Name speakers without the GUI: comma-separated <number>=<name> pairs, e.g. \"1=Ben,2=Jordan Whitfield\". Speakers left out keep their Speaker_N placeholder.")
    public var speakers: String?

    public init() {}
}

/// `auricle keep <id> [--quiet]`.
public struct KeepArguments: ParsableArguments {
    @Argument(help: "Meeting ID.")
    public var id: String

    @Flag(help: "Suppress stdout output; exit code only.")
    public var quiet = false

    public init() {}
}

/// `auricle list [--all] [--json]`.
public struct ListArguments: ParsableArguments {
    @Flag(help: "Include verified and discarded meetings.")
    public var all = false

    @Flag(help: "Output machine-readable JSON.")
    public var json = false

    public init() {}
}

/// `auricle status <id> [--json]`.
public struct StatusArguments: ParsableArguments {
    @Argument(help: "Meeting ID.")
    public var id: String

    @Flag(help: "Output machine-readable JSON.")
    public var json = false

    public init() {}
}

/// `auricle config get [<key>]`.
public struct ConfigGetArguments: ParsableArguments {
    @Argument(help: "Config key.")
    public var key: String?

    public init() {}
}

/// `auricle config set <key> <value>`.
public struct ConfigSetArguments: ParsableArguments {
    @Argument(help: "Config key.")
    public var key: String

    @Argument(help: "Value to write.")
    public var value: String

    public init() {}
}

/// `auricle __internal-import <audio-file> [--started-at <ISO 8601>] [--title <text>]`.
/// Hidden and exempt from the NFR-I7 binding contract, like `__internal-stage`.
public struct ImportArguments: ParsableArguments {
    public static let commandName = "__internal-import"

    @Argument(help: "Path to the audio file to register.")
    public var audioFile: String

    @Option(help: "When the meeting started, as ISO 8601. Defaults to the file's creation date.")
    public var startedAt: String?

    @Option(help: "Meeting title.")
    public var title: String?

    public init() {}
}
