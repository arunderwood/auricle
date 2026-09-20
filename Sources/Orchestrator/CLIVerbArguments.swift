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
}

/// `auricle attribute <id> [--batch]`.
public struct AttributeArguments: ParsableArguments {
    @Argument(help: "Meeting ID.")
    public var id: String

    @Flag(help: "Apply the last-known speaker mapping instead of opening the GUI.")
    public var batch = false

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
