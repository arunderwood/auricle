import ArgumentParser

struct RunVerb: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the pipeline forward from a meeting's current state."
    )

    @Argument(help: "Meeting ID.")
    var id: String

    @Flag(help: "Re-run all stages from the beginning, even if already published.")
    var force = false

    // Plain strings, not `PipelineStage`, per Decision 1.5: the orthogonal
    // stage-control flags must keep working unmodified as later epics add
    // pipeline stages, without this argument surface needing a rebuild.
    @Option(help: "Run forward starting at <stage>.")
    var from: String?

    @Option(help: "Run forward up to and including <stage>.")
    var to: String?

    @Option(help: "Run only <stage>.")
    var only: String?

    @Flag(help: "Alias for --from attribute; preserves the armed retention timer.")
    var reattribute = false

    @Flag(help: "Skip attribution and publish with Speaker_N placeholder names.")
    var publishAnyway = false

    func run() async throws {
        try notYetImplemented("run")
    }
}
